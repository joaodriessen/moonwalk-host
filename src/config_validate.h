/**
 * @file config_validate.h
 * @brief Declarations for validating a posted `saveConfig` key/value bag against
 *        `config_schema.json` (docs/design/config-schema-ssot.md, stage 3).
 *
 * Kept free of any HTTP/server dependency so it can be unit tested directly.
 */
#pragma once

// standard includes
#include <optional>
#include <string>
#include <vector>

// lib includes
#include <nlohmann/json.hpp>

namespace config_validate {
  /**
   * @brief A single rejected key/value pair from a posted config bag.
   */
  struct violation_t {
    std::string key;  ///< The offending option name.
    std::string value;  ///< The offending value, stringified for display.
    std::string reason;  ///< Human-readable reason the value was rejected.
  };

  /**
   * @brief The outcome of validating a posted config bag against the schema.
   */
  struct result_t {
    /// True iff every known key in the posted bag passed type/range/enum checks.
    /// Unknown keys never affect this -- they are warn-and-preserve, not a rejection.
    bool ok = true;

    /// Every violation found among *known* keys (all of them, not just the first).
    std::vector<violation_t> violations;

    /// Names of posted keys that do not appear in the schema at all. Per design,
    /// these are logged as a warning by the caller and still written through unchanged.
    std::vector<std::string> unknown_keys;
  };

  /**
   * @brief Load and parse `config_schema.json` from disk.
   * @param schema_path Path to `config_schema.json` (e.g. `WEB_DIR "config_schema.json"`).
   * @return The parsed schema document, or `std::nullopt` if the file is missing, unreadable,
   *         not valid JSON, or missing a top-level `options` array.
   */
  std::optional<nlohmann::json> load_schema(const std::string &schema_path);

  /**
   * @brief Validate a posted config key/value bag against a parsed `config_schema.json`.
   *
   * For every key present in the schema's `options[]`: type-checks the value (int/bool/double
   * must be parseable as that type; string/path/enum-without-`constraints.enum` must be a JSON
   * string; `object`/`list`/`map` are passed through unchecked), then enforces
   * `constraints.min`/`constraints.max` (when present) and `constraints.enum` (when present).
   * All violations are collected -- validation does not stop at the first bad key.
   *
   * Keys not present in the schema are recorded in `result_t::unknown_keys` and are never a
   * violation (warn-and-preserve, per docs/design/config-schema-ssot.md).
   *
   * Values that would be skipped by `saveConfig`'s existing write logic (`null`, or an empty
   * string) are skipped here too -- they are never written today, so they are not validated.
   *
   * @param schema The parsed schema document (see `load_schema()`).
   * @param posted The posted key/value JSON object, as received from `POST /api/config`.
   * @return A `result_t` describing every violation and every unknown key found.
   */
  result_t validate(const nlohmann::json &schema, const nlohmann::json &posted);

  /**
   * @brief Render a `result_t`'s violations as the JSON body returned to the client on HTTP 400.
   * @param result A result with `ok == false`.
   * @return `{"errors": [{"key": ..., "value": ..., "reason": ...}, ...]}`.
   */
  nlohmann::json violations_to_json(const result_t &result);
}  // namespace config_validate
