/**
 * @file config_validate.cpp
 * @brief Definitions for validating a posted `saveConfig` key/value bag against
 *        `config_schema.json` (docs/design/config-schema-ssot.md, stage 3).
 */

// standard includes
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <unordered_map>
#include <unordered_set>

// local includes
#include "config_validate.h"
#include "file_handler.h"
#include "logging.h"

namespace config_validate {
  namespace {
    // Stringify a posted JSON value for display in a violation message. Mirrors the
    // string-vs-dump split saveConfig() already uses when writing the conf file.
    std::string stringify(const nlohmann::json &v) {
      return v.is_string() ? v.get<std::string>() : v.dump();
    }

    // Same "nothing to validate/write" predicate saveConfig() already applies to every
    // posted key before writing it -- null or empty-string values are skipped entirely,
    // known or unknown, so they are never validated either.
    bool is_skippable_value(const nlohmann::json &v) {
      return v.is_null() || (v.is_string() && v.get<std::string>().empty());
    }

    // Trim ASCII whitespace from both ends.
    std::string trim(const std::string &s) {
      size_t begin = 0;
      size_t end = s.size();
      while (begin < end && std::isspace(static_cast<unsigned char>(s[begin]))) {
        ++begin;
      }
      while (end > begin && std::isspace(static_cast<unsigned char>(s[end - 1]))) {
        --end;
      }
      return s.substr(begin, end - begin);
    }

    // Truthy/falsy string vocabulary mirrors config.cpp's bool_f()/to_bool() (config.cpp:840-857)
    // -- that function is the single source of truth for what a saved config string means
    // "true"/"false", and it is NOT just JSON true/false: the web UI's Checkbox.vue posts
    // "enabled"/"disabled" (config.html tab defaults use the same strings), so the save-path
    // validator must accept exactly what the load path accepts or every checkbox option 400s.
    // Compared case-insensitively, matching to_bool()'s intent (its own lowercasing is a no-op
    // bug -- std::for_each with a value-returning, non-mutating lambda -- so to_bool() is
    // actually case-sensitive in practice; we deliberately fix that here rather than reproduce
    // the bug, since case-insensitivity is what to_bool() was clearly meant to do).
    // One intentional divergence: to_bool()'s truthy check also matches if the string contains a
    // '1' character *anywhere* (`std::find(..., '1')`), which is an artifact of that lowercasing
    // bug's neighboring logic, not a documented wire format -- reproducing it here would make
    // almost any string starting with "1" a false positive in a validator whose whole job is to
    // reject bad input. This uses an exact token match against the same named vocabulary instead.
    // Keep this set in sync with config.cpp's to_bool() if that function's vocabulary changes.
    std::optional<bool> try_parse_bool(const nlohmann::json &v) {
      if (v.is_boolean()) {
        return v.get<bool>();
      }
      if (v.is_string()) {
        std::string s = trim(v.get<std::string>());
        for (auto &c : s) {
          c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }

        static const std::unordered_set<std::string> truthy = {"true", "yes", "enable", "enabled", "on", "1"};
        static const std::unordered_set<std::string> falsy = {"false", "no", "disable", "disabled", "off", "0"};

        if (truthy.count(s)) {
          return true;
        }
        if (falsy.count(s)) {
          return false;
        }
      }
      return std::nullopt;
    }

    std::optional<long long> try_parse_int(const nlohmann::json &v) {
      if (v.is_number_integer() || v.is_number_unsigned()) {
        return v.get<long long>();
      }
      if (v.is_number_float()) {
        double d = v.get<double>();
        long long truncated = static_cast<long long>(d);
        if (static_cast<double>(truncated) == d) {
          return truncated;
        }
        return std::nullopt;
      }
      if (v.is_string()) {
        std::string s = trim(v.get<std::string>());
        if (s.empty()) {
          return std::nullopt;
        }
        // Strip a single layer of surrounding quotes, matching config.cpp's int_f() leniency
        // for values like `"756"` that came from a hand-edited conf.
        if (s.size() >= 2 && s.front() == '"' && s.back() == '"') {
          s = s.substr(1, s.size() - 2);
        }
        if (s.empty()) {
          return std::nullopt;
        }
        char *end = nullptr;
        errno = 0;
        long long parsed = 0;
        // Mirror config::int_f()'s loader semantics exactly (config.cpp / utility.h's
        // from_view): a leading "0x" prefix means hex, everything else is decimal. The
        // loader never auto-detects octal from a leading zero, but strtoll's base-0 mode
        // does — that mismatch let a value like "05000" validate here as octal 2560
        // (passing a max=3000 bound) while the loader parsed the same string as decimal
        // 5000 on load, silently bypassing the declared bound. Parse in the same base the
        // loader uses so both stages agree on the same number.
        if (s.size() > 2 && s[0] == '0' && s[1] == 'x') {
          parsed = std::strtoll(s.c_str() + 2, &end, 16);
        } else {
          parsed = std::strtoll(s.c_str(), &end, 10);
        }
        if (end != s.c_str() + s.size() || errno == ERANGE) {
          return std::nullopt;
        }
        return parsed;
      }
      return std::nullopt;
    }

    std::optional<double> try_parse_double(const nlohmann::json &v) {
      if (v.is_number()) {
        return v.get<double>();
      }
      if (v.is_string()) {
        std::string s = trim(v.get<std::string>());
        if (s.empty()) {
          return std::nullopt;
        }
        char *end = nullptr;
        errno = 0;
        double parsed = std::strtod(s.c_str(), &end);
        if (end != s.c_str() + s.size() || errno == ERANGE) {
          return std::nullopt;
        }
        return parsed;
      }
      return std::nullopt;
    }

    // Validate one known option's posted value against its schema entry. Appends to
    // `violations` on failure; never throws.
    void validate_known_option(const std::string &key, const nlohmann::json &value, const nlohmann::json &option, std::vector<violation_t> &violations) {
      const std::string type = option.value("type", "");
      const nlohmann::json *constraints = option.contains("constraints") && option["constraints"].is_object() ? &option["constraints"] : nullptr;

      // SECURITY: reject an embedded newline in the key, or in a string/path/enum value, BEFORE
      // any other check. saveConfig() (confighttp.cpp) writes `key = value` lines straight to
      // sunshine.conf, and config::parse_config() (config.cpp) splits that file strictly
      // line-by-line on reload -- an unguarded "\n"/"\r" here lets an authenticated POST inject a
      // second, unvalidated config directive, e.g. {"some_key": "x\nglobal_prep_cmd = [...]"}
      // would add a live global_prep_cmd hook (arbitrary shell execution on every session start).
      // This mirrors the identical guard already shipped in xpc_control.mm's SetConfValue() for
      // the XPC write path -- same bug class, same fix, on the other writer.
      if (key.find('\n') != std::string::npos || key.find('\r') != std::string::npos) {
        violations.push_back({key, stringify(value), "key contains an embedded newline"});
        return;
      }
      if ((type == "string" || type == "path" || type == "enum") && value.is_string()) {
        const std::string s = value.get<std::string>();
        if (s.find('\n') != std::string::npos || s.find('\r') != std::string::npos) {
          violations.push_back({key, stringify(value), "value contains an embedded newline"});
          return;
        }
      }

      const bool has_enum = constraints && constraints->contains("enum") && (*constraints)["enum"].is_array();

      // constraints.enum wins regardless of the declared type -- it is the strictest, most
      // specific rule the schema can express for a key.
      if (has_enum) {
        if (!value.is_string()) {
          violations.push_back({key, stringify(value), "expected a string matching one of the allowed values"});
          return;
        }
        const std::string s = value.get<std::string>();
        bool found = false;
        for (const auto &allowed : (*constraints)["enum"]) {
          if (allowed.is_string() && allowed.get<std::string>() == s) {
            found = true;
            break;
          }
        }
        if (!found) {
          violations.push_back({key, stringify(value), "value is not one of the allowed enum values"});
        }
        return;
      }

      if (type == "bool") {
        if (!try_parse_bool(value)) {
          violations.push_back({key, stringify(value), "expected a boolean"});
        }
        return;
      }

      if (type == "int") {
        auto parsed = try_parse_int(value);
        if (!parsed) {
          violations.push_back({key, stringify(value), "expected an integer"});
          return;
        }
        if (constraints) {
          if (constraints->contains("min") && !(*constraints)["min"].is_null() && *parsed < (*constraints)["min"].get<long long>()) {
            violations.push_back({key, stringify(value), "value is below the minimum allowed"});
            return;
          }
          if (constraints->contains("max") && !(*constraints)["max"].is_null() && *parsed > (*constraints)["max"].get<long long>()) {
            violations.push_back({key, stringify(value), "value is above the maximum allowed"});
            return;
          }
        }
        return;
      }

      if (type == "double") {
        auto parsed = try_parse_double(value);
        if (!parsed) {
          violations.push_back({key, stringify(value), "expected a number"});
          return;
        }
        if (constraints) {
          if (constraints->contains("min") && !(*constraints)["min"].is_null() && *parsed < (*constraints)["min"].get<double>()) {
            violations.push_back({key, stringify(value), "value is below the minimum allowed"});
            return;
          }
          if (constraints->contains("max") && !(*constraints)["max"].is_null() && *parsed > (*constraints)["max"].get<double>()) {
            violations.push_back({key, stringify(value), "value is above the maximum allowed"});
            return;
          }
        }
        return;
      }

      if (type == "string" || type == "path" || type == "enum") {
        // "enum" without constraints.enum is a dynamic/unconstrained allow-list (e.g. gamepad's
        // runtime-populated list, or the parser's unconstrained string_f enums) -- per
        // docs/design/config-schema-ssot.md, validate as a plain string only. Do NOT invent an
        // enum allow-list here.
        if (!value.is_string()) {
          violations.push_back({key, stringify(value), "expected a string"});
        }
        return;
      }

      // type == "object" | "list" | "map" (or anything else future schema versions add):
      // not in the design's explicit type-check list (int/bool/double parseable, range, enum).
      // Pass through unchecked.
    }
  }  // namespace

  std::optional<nlohmann::json> load_schema(const std::string &schema_path) {
    if (!std::filesystem::exists(schema_path)) {
      return std::nullopt;
    }

    const std::string content = file_handler::read_file(schema_path.c_str());
    if (content.empty()) {
      return std::nullopt;
    }

    nlohmann::json parsed;
    try {
      parsed = nlohmann::json::parse(content);
    } catch (const nlohmann::json::parse_error &) {
      return std::nullopt;
    }

    if (!parsed.is_object() || !parsed.contains("options") || !parsed["options"].is_array()) {
      return std::nullopt;
    }

    return parsed;
  }

  result_t validate(const nlohmann::json &schema, const nlohmann::json &posted) {
    result_t result;

    std::unordered_map<std::string, const nlohmann::json *> options_by_name;
    if (schema.contains("options") && schema["options"].is_array()) {
      for (const auto &option : schema["options"]) {
        if (option.contains("name") && option["name"].is_string()) {
          options_by_name.emplace(option["name"].get<std::string>(), &option);
        }
      }
    }

    if (!posted.is_object()) {
      // Not our job to shape-check the outer envelope -- callers already require
      // application/json and parse it before calling validate(). Nothing to do.
      return result;
    }

    for (const auto &[key, value] : posted.items()) {
      if (is_skippable_value(value)) {
        continue;
      }

      // SECURITY: reject an embedded newline in the key itself before doing anything else with
      // it, REGARDLESS of whether it matches a known schema option. A key can never legitimately
      // contain \n/\r, and an attacker who wants to inject a second `key = value` config line
      // (see the identical guard in validate_known_option() below, and xpc_control.mm's
      // SetConfValue()) would naturally smuggle the injected line inside the KEY string itself
      // (e.g. posting {"foo\nglobal_prep_cmd": "[...]"}), which never matches a real schema
      // option name and would otherwise sail through as an "unknown key" below.
      if (key.find('\n') != std::string::npos || key.find('\r') != std::string::npos) {
        result.violations.push_back({key, stringify(value), "key contains an embedded newline"});
        continue;
      }

      auto it = options_by_name.find(key);
      if (it == options_by_name.end()) {
        // Unknown keys skip type/range/enum validation by design (see saveConfig()'s doc
        // comment: "written through unchanged"), but they are still written verbatim as
        // `key = value` -- so a string value here still needs the same newline guard
        // validate_known_option() applies to known string/path/enum options, or an unknown key
        // is a free pass around the RCE guard below it.
        if (value.is_string()) {
          const std::string s = value.get<std::string>();
          if (s.find('\n') != std::string::npos || s.find('\r') != std::string::npos) {
            result.violations.push_back({key, stringify(value), "value contains an embedded newline"});
            continue;
          }
        }
        result.unknown_keys.push_back(key);
        continue;
      }

      validate_known_option(key, value, *it->second, result.violations);
    }

    result.ok = result.violations.empty();
    return result;
  }

  nlohmann::json violations_to_json(const result_t &result) {
    nlohmann::json errors = nlohmann::json::array();
    for (const auto &violation : result.violations) {
      errors.push_back({
        {"key", violation.key},
        {"value", violation.value},
        {"reason", violation.reason},
      });
    }

    nlohmann::json body;
    body["errors"] = std::move(errors);
    return body;
  }
}  // namespace config_validate
