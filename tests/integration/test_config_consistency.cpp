/**
 * @file tests/integration/test_config_consistency.cpp
 * @brief Test configuration consistency across all configuration files
 */
#include "../tests_common.h"

// standard includes
#include <algorithm>
#include <filesystem>
#include <format>
#include <fstream>
#include <map>
#include <optional>
#include <ranges>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

// lib includes
#include <nlohmann/json.hpp>

// local includes
#include "src/file_handler.h"

class ConfigConsistencyTest: public ::testing::Test {
protected:
  void SetUp() override {
    // Define the expected mapping between documentation sections and UI tabs
    expectedDocToTabMapping = {
      {"General", "general"},
      {"Input", "input"},
      {"Audio/Video", "av"},
      {"Network", "network"},
      {"Config Files", "files"},
      {"Advanced", "advanced"},
      {"NVIDIA NVENC Encoder", "nv"},
      {"Intel QuickSync Encoder", "qsv"},
      {"AMD AMF Encoder", "amd"},
      {"VideoToolbox Encoder", "vt"},
      {"VA-API Encoder", "vaapi"},
      {"Software Encoder", "sw"}
    };
  }

  // Repo-root-relative paths (e.g. "src/config.cpp") only resolve correctly when the test binary
  // happens to be invoked with cwd == the directory tests/CMakeLists.txt's configure_file() copies
  // land in (build/tests). CI/the steward run `cd build && ./tests/test_sunshine`, i.e. cwd == the
  // build/ *parent* dir, where those relative paths silently miss (file_handler::read_file()
  // returns "" for a missing file rather than throwing) and calling tests either see empty content
  // or -- for tests that ASSERT on the file being present, like the schema ones below -- fail
  // outright. SUNSHINE_SOURCE_DIR is a compile definition set by tests/CMakeLists.txt
  // (TEST_DEFINITIONS, ~line 79) to the absolute repo root; anchor every file read here to it so
  // resolution is independent of the invoking cwd. (Mirrors tests/unit/test_process.cpp's use of
  // the same macro.)
  static std::filesystem::path sourceDir() {
    return std::filesystem::path(SUNSHINE_SOURCE_DIR);
  }

  static std::string sourcePath(const std::string &relative) {
    return (sourceDir() / relative).string();
  }

  // Extract config options from config.cpp - the authoritative source
  static std::set<std::string, std::less<>> extractConfigCppOptions() {
    std::set<std::string, std::less<>> options;
    std::string content = file_handler::read_file(sourcePath("src/config.cpp").c_str());

    // Regex patterns to match different config option types in config.cpp
    const std::vector patterns = {
      std::regex(R"DELIM((?:string_f|path_f|string_restricted_f)\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM((?:int_f|int_between_f)\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM(bool_f\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM((?:double_f|double_between_f)\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM(generic_f\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM(list_prep_cmd_f\s*\(\s*vars\s*,\s*"([^"]+)")DELIM"),
      std::regex(R"DELIM(map_int_int_f\s*\(\s*vars\s*,\s*"([^"]+)")DELIM")
    };

    for (const auto &pattern : patterns) {
      std::sregex_iterator iter(content.begin(), content.end(), pattern);

      for (std::sregex_iterator end; iter != end; ++iter) {
        std::string optionName = (*iter)[1].str();
        options.insert(optionName);
      }
    }

    return options;
  }

  // Helper function to find brace boundaries
  static size_t findClosingBrace(const std::string &content, const size_t start) {
    size_t pos = start + 1;
    int braceLevel = 1;

    while (pos < content.length() && braceLevel > 0) {
      if (content[pos] == '{') {
        braceLevel++;
      } else if (content[pos] == '}') {
        braceLevel--;
      }
      pos++;
    }

    return pos - 1;
  }

  // Helper function to extract tab ID from a tab object
  static std::string extractTabId(const std::string &tabObject) {
    const std::regex idPattern(R"DELIM(id:\s*"([^"]+)")DELIM");

    if (std::smatch idMatch; std::regex_search(tabObject, idMatch, idPattern)) {
      return idMatch[1].str();
    }

    return "";
  }

  // Helper function to find and extract tabs content from HTML
  static std::string extractTabsContent(const std::string &content) {
    const size_t tabsStart = content.find("tabs: [");
    if (tabsStart == std::string::npos) {
      return "";
    }

    // Find the end of the tab array
    size_t pos = tabsStart + 7;  // Skip "tabs: ["
    int bracketLevel = 1;
    size_t tabsEnd = pos;

    while (pos < content.length() && bracketLevel > 0) {
      if (content[pos] == '[') {
        bracketLevel++;
      } else if (content[pos] == ']') {
        bracketLevel--;
      }
      tabsEnd = pos;
      pos++;
    }

    return content.substr(tabsStart + 7, tabsEnd - tabsStart - 7);
  }

  // Helper function to extract options from a tab object (generic version)
  template<typename Container>
  static void extractOptionsFromTabGeneric(const std::string &tabObject, Container &container) {
    const std::string tabId = extractTabId(tabObject);
    if (tabId.empty()) {
      return;
    }

    const size_t optionsStart = tabObject.find("options:");
    if (optionsStart == std::string::npos) {
      return;
    }

    const size_t optStart = tabObject.find('{', optionsStart);
    if (optStart == std::string::npos) {
      return;
    }

    const size_t optEnd = findClosingBrace(tabObject, optStart);
    std::string optionsSection = tabObject.substr(optStart + 1, optEnd - optStart - 1);

    // Extract option names
    const std::regex optionPattern(R"DELIM("([^"]+)":\s*)DELIM");
    std::sregex_iterator optionIter(optionsSection.begin(), optionsSection.end(), optionPattern);

    for (const std::sregex_iterator optionEnd; optionIter != optionEnd; ++optionIter) {
      std::string optionName = (*optionIter)[1].str();

      // Use if constexpr to handle different container types
      if constexpr (std::is_same_v<Container, std::map<std::string, std::string, std::less<>>>) {
        container[optionName] = tabId;
      } else if constexpr (std::is_same_v<Container, std::map<std::string, std::vector<std::string>, std::less<>>>) {
        container[tabId].push_back(optionName);
      }
    }
  }

  // Helper function to process tab objects from tabs content
  template<typename Container>
  static void processTabObjects(const std::string &tabsContent, Container &container) {
    size_t tabPos = 0;
    while (tabPos < tabsContent.length()) {
      const size_t objStart = tabsContent.find('{', tabPos);
      if (objStart == std::string::npos) {
        break;
      }

      const size_t objEnd = findClosingBrace(tabsContent, objStart);
      std::string tabObject = tabsContent.substr(objStart, objEnd - objStart + 1);

      extractOptionsFromTabGeneric(tabObject, container);

      tabPos = objEnd + 1;
    }
  }

  // Helper function to trim whitespace from string
  static void trimWhitespace(std::string &str) {
    str.erase(str.find_last_not_of(" \t\r\n") + 1);
  }

  // Helper function to extract option name from the Markdown line
  static std::string extractOptionFromMarkdownLine(const std::string &line) {
    const std::regex optionPattern(R"(^### ([^#\r\n]+))");
    if (std::smatch optionMatch; std::regex_search(line, optionMatch, optionPattern)) {
      std::string optionName = optionMatch[1].str();
      trimWhitespace(optionName);
      return optionName;
    }
    return "";
  }

  // Extract config options from config.html
  static std::map<std::string, std::string, std::less<>> extractConfigHtmlOptions() {
    std::map<std::string, std::string, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("src_assets/common/assets/web/config.html").c_str());

    const std::string tabsContent = extractTabsContent(content);
    if (tabsContent.empty()) {
      return options;
    }

    processTabObjects(tabsContent, options);
    return options;
  }

  // Helper function to extract options from a single tab object (now using generic function)
  static void extractOptionsFromTab(const std::string &tabObject, std::map<std::string, std::vector<std::string>, std::less<>> &optionsByTab) {
    extractOptionsFromTabGeneric(tabObject, optionsByTab);
  }

  // Extract config options from config.html with order preserved
  static std::map<std::string, std::vector<std::string>, std::less<>> extractConfigHtmlOptionsWithOrder() {
    std::map<std::string, std::vector<std::string>, std::less<>> optionsByTab;
    const std::string content = file_handler::read_file(sourcePath("src_assets/common/assets/web/config.html").c_str());

    const std::string tabsContent = extractTabsContent(content);
    if (tabsContent.empty()) {
      return optionsByTab;
    }

    processTabObjects(tabsContent, optionsByTab);
    return optionsByTab;
  }

  // Helper function to process markdown line for section headers
  static bool processSectionHeader(const std::string &line, std::string &currentSection) {
    const std::regex sectionPattern(R"(^## ([^#\r\n]+))");

    if (std::smatch sectionMatch; std::regex_search(line, sectionMatch, sectionPattern)) {
      currentSection = sectionMatch[1].str();
      trimWhitespace(currentSection);
      return true;
    }

    return false;
  }

  // Helper function to process markdown line for option headers
  static bool processOptionHeader(const std::string &line, const std::string_view currentSection, std::map<std::string, std::string, std::less<>> &options) {
    if (currentSection.empty()) {
      return false;
    }

    if (const std::string optionName = extractOptionFromMarkdownLine(line); !optionName.empty()) {
      options[optionName] = currentSection;
      return true;
    }

    return false;
  }

  // Extract config options from configuration.md
  static std::map<std::string, std::string, std::less<>> extractConfigMdOptions() {
    std::map<std::string, std::string, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("docs/configuration.md").c_str());

    std::istringstream stream(content);
    std::string line;
    std::string currentSection;

    while (std::getline(stream, line)) {
      if (processSectionHeader(line, currentSection)) {
        continue;
      }

      processOptionHeader(line, currentSection, options);
    }

    return options;
  }

  // Helper function to process markdown option line for order-preserved extraction
  static void processMarkdownOptionLine(const std::string &line, const std::string &currentSection, std::map<std::string, std::vector<std::string>, std::less<>> &optionsBySection) {
    if (currentSection.empty()) {
      return;
    }

    if (const std::string optionName = extractOptionFromMarkdownLine(line); !optionName.empty()) {
      optionsBySection[currentSection].push_back(optionName);
    }
  }

  // Extract config options from configuration.md with order preserved
  static std::map<std::string, std::vector<std::string>, std::less<>> extractConfigMdOptionsWithOrder() {
    std::map<std::string, std::vector<std::string>, std::less<>> optionsBySection;
    const std::string content = file_handler::read_file(sourcePath("docs/configuration.md").c_str());

    std::istringstream stream(content);
    std::string line;
    std::string currentSection;

    while (std::getline(stream, line)) {
      if (processSectionHeader(line, currentSection)) {
        continue;
      }

      processMarkdownOptionLine(line, currentSection, optionsBySection);
    }

    return optionsBySection;
  }

  // Helper function to find the config section end
  static size_t findConfigSectionEnd(const std::string &content, size_t configStart) {
    size_t braceCount = 1;
    size_t configEnd = configStart;

    while (configStart < content.length() && braceCount > 0) {
      if (content[configStart] == '{') {
        braceCount++;
      } else if (content[configStart] == '}') {
        braceCount--;
      }
      configEnd = configStart;
      configStart++;
    }

    return configEnd;
  }

  // Helper function to extract keys from a config section
  static void extractKeysFromConfigSection(const std::string_view configSection, std::set<std::string, std::less<>> &options) {
    const std::regex keyPattern(R"DELIM("([^"]+)":\s*)DELIM");
    std::string configStr(configSection);
    std::sregex_iterator iter(configStr.begin(), configStr.end(), keyPattern);

    for (const std::sregex_iterator end; iter != end; ++iter) {
      options.insert((*iter)[1].str());
    }
  }

  // Extract config options from en.json
  static std::set<std::string, std::less<>> extractEnJsonConfigOptions() {
    std::set<std::string, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("src_assets/common/assets/web/public/assets/locale/en.json").c_str());

    // Look for the config section
    const std::regex configSectionPattern(R"DELIM("config":\s*\{)DELIM");
    std::smatch match;

    if (!std::regex_search(content, match, configSectionPattern)) {
      return options;
    }

    // Find the config section and extract keys
    const size_t configStart = match.position() + match.length();
    const size_t configEnd = findConfigSectionEnd(content, configStart);
    const std::string configSection = content.substr(configStart, configEnd - configStart);

    extractKeysFromConfigSection(configSection, options);

    return options;
  }

  std::map<std::string, std::string, std::less<>> expectedDocToTabMapping;

  // Helper function to check if a test fake option is found in missing files
  static void checkTestDummyDetection(const std::vector<std::string> &missingFromFiles, const std::string &testDummyOption, bool &foundMissingDummyInHtml, bool &foundMissingDummyInMd, bool &foundMissingDummyInJson) {
    for (const auto &missing : missingFromFiles) {
      if (!missing.contains(testDummyOption)) {
        continue;
      }

      if (missing.contains("config.html")) {
        foundMissingDummyInHtml = true;
      }
      if (missing.contains("configuration.md")) {
        foundMissingDummyInMd = true;
      }
      if (missing.contains("en.json")) {
        foundMissingDummyInJson = true;
      }
    }
  }

  // Helper function to create comma-separated string from vector
  static std::string buildCommaSeparatedString(const std::vector<std::string> &options) {
    std::string result;
    for (size_t i = 0; i < options.size(); ++i) {
      if (i > 0) {
        result += ", ";
      }
      result += options[i];
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // config_schema.json support (docs/design/config-schema-ssot.md, stage 1+2)
  // ---------------------------------------------------------------------

  static constexpr std::string_view kSchemaPath = "src_assets/common/assets/web/config_schema.json";

  // Metadata extracted from a single schema option entry, used for type/enum/range parity.
  struct SchemaOption {
    std::string type;
    std::optional<long long> min;
    std::optional<long long> max;
    bool hasRange = false;
    std::vector<std::string> enumValues;
    bool hasEnum = false;
  };

  // Absolute path to config_schema.json, anchored to SUNSHINE_SOURCE_DIR (see sourcePath()).
  static std::string schemaAbsolutePath() {
    return sourcePath(std::string(kSchemaPath));
  }

  // Load and parse config_schema.json. Returns std::nullopt if the file is missing or invalid,
  // callers are expected to FAIL (not skip) on that -- the schema is committed alongside the
  // code it documents, so "missing" is a real regression, not an environment quirk.
  static std::optional<nlohmann::json> loadConfigSchema() {
    if (!std::filesystem::exists(schemaAbsolutePath())) {
      return std::nullopt;
    }

    const std::string content = file_handler::read_file(schemaAbsolutePath().c_str());
    try {
      return nlohmann::json::parse(content);
    } catch (const nlohmann::json::parse_error &) {
      return std::nullopt;
    }
  }

  // Extract just the option names declared in config_schema.json's options[] array.
  static std::set<std::string, std::less<>> extractSchemaOptionNames(const nlohmann::json &schema) {
    std::set<std::string, std::less<>> names;
    if (!schema.contains("options") || !schema["options"].is_array()) {
      return names;
    }

    for (const auto &opt : schema["options"]) {
      if (opt.contains("name") && opt["name"].is_string()) {
        names.insert(opt["name"].get<std::string>());
      }
    }

    return names;
  }

  // Extract full per-option metadata (type/min/max/enum) keyed by option name.
  static std::map<std::string, SchemaOption, std::less<>> extractSchemaOptions(const nlohmann::json &schema) {
    std::map<std::string, SchemaOption, std::less<>> options;
    if (!schema.contains("options") || !schema["options"].is_array()) {
      return options;
    }

    for (const auto &opt : schema["options"]) {
      if (!opt.contains("name") || !opt["name"].is_string()) {
        continue;
      }

      SchemaOption entry;
      entry.type = opt.value("type", "");

      if (opt.contains("constraints") && opt["constraints"].is_object()) {
        const auto &constraints = opt["constraints"];

        if (constraints.contains("min") && constraints["min"].is_number()) {
          entry.min = constraints["min"].get<long long>();
          entry.hasRange = true;
        }
        if (constraints.contains("max") && constraints["max"].is_number()) {
          entry.max = constraints["max"].get<long long>();
          entry.hasRange = true;
        }
        if (constraints.contains("enum") && constraints["enum"].is_array()) {
          entry.hasEnum = true;
          for (const auto &val : constraints["enum"]) {
            if (val.is_string()) {
              entry.enumValues.push_back(val.get<std::string>());
            }
          }
        }
      }

      options[opt["name"].get<std::string>()] = std::move(entry);
    }

    return options;
  }

  // Extract option names parsed via bool_f(vars, "name", ...) in config.cpp -- parser truth for
  // which options should be schema type "bool".
  static std::set<std::string, std::less<>> extractConfigCppBoolOptions() {
    std::set<std::string, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("src/config.cpp").c_str());
    const std::regex pattern(R"DELIM(bool_f\s*\(\s*vars\s*,\s*"([^"]+)")DELIM");

    for (std::sregex_iterator iter(content.begin(), content.end(), pattern), end; iter != end; ++iter) {
      options.insert((*iter)[1].str());
    }

    return options;
  }

  // Extract literal {min, max} bounds from int_between_f(vars, "name", var, {min, max}) calls in
  // config.cpp. Bounds that aren't plain integer literals (e.g. std::numeric_limits<int>::max(),
  // or the computed port range) can't be resolved by regex and are left unset -- callers only
  // assert parity for the bound(s) that *were* resolved, per the "where the test can reach them"
  // scope in docs/design/config-schema-ssot.md.
  static std::map<std::string, SchemaOption, std::less<>> extractConfigCppIntBetweenOptions() {
    return extractBetweenOptions(R"DELIM((?:int_between_f)\s*\(\s*vars\s*,\s*"([^"]+)"\s*,\s*[^,]+,\s*\{([^}]*)\}\s*\))DELIM");
  }

  // Same as above but for double_between_f(...).
  static std::map<std::string, SchemaOption, std::less<>> extractConfigCppDoubleBetweenOptions() {
    return extractBetweenOptions(R"DELIM((?:double_between_f)\s*\(\s*vars\s*,\s*"([^"]+)"\s*,\s*[^,]+,\s*\{([^}]*)\}\s*\))DELIM");
  }

  // Shared implementation for the two helpers above.
  static std::map<std::string, SchemaOption, std::less<>> extractBetweenOptions(const std::string &patternStr) {
    std::map<std::string, SchemaOption, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("src/config.cpp").c_str());
    const std::regex pattern(patternStr);

    for (std::sregex_iterator iter(content.begin(), content.end(), pattern), end; iter != end; ++iter) {
      const std::string name = (*iter)[1].str();
      const std::string body = (*iter)[2].str();

      const auto commaPos = body.find(',');
      if (commaPos == std::string::npos) {
        continue;
      }

      std::string minText = body.substr(0, commaPos);
      std::string maxText = body.substr(commaPos + 1);
      trimWhitespace(minText);
      trimWhitespace(maxText);

      SchemaOption entry;
      entry.hasRange = true;
      if (auto v = parseLiteralInt(minText)) {
        entry.min = v;
      }
      if (auto v = parseLiteralInt(maxText)) {
        entry.max = v;
      }

      // Only keep it if there's a call for this option already (map_int_int_f/keybindings can
      // false-positive-match "int_between_f" via substring overlap -- see extractConfigCppOptions
      // doc comment); a range call always yields a genuine {min,max} literal-or-symbolic pair,
      // so this is purely additive and safe to just overwrite/insert.
      options[name] = entry;
    }

    return options;
  }

  // Parse a trimmed range-bound token as a plain (optionally negative) integer literal.
  // Returns std::nullopt for symbolic expressions like "std::numeric_limits<int>::max()" or
  // "1024 + nvhttp::PORT_HTTPS", which regex extraction cannot resolve.
  static std::optional<long long> parseLiteralInt(const std::string &text) {
    static const std::regex literalPattern(R"(^-?\d+$)");
    if (!std::regex_match(text, literalPattern)) {
      return std::nullopt;
    }
    return std::stoll(text);
  }

  // Extract literal enum allow-lists from string_restricted_f(vars, "name", var, {"a"sv, "b"sv})
  // calls in config.cpp. When the last argument is a function call instead of a brace-list (e.g.
  // "gamepad"'s get_supported_gamepad_options(), which is populated at runtime from
  // platf::supported_gamepads()), the regex simply won't match -- that option is intentionally
  // absent from the returned map, matching the schema's "dynamic_enum" discrepancy entry.
  static std::map<std::string, std::vector<std::string>, std::less<>> extractConfigCppStringRestrictedEnums() {
    std::map<std::string, std::vector<std::string>, std::less<>> options;
    const std::string content = file_handler::read_file(sourcePath("src/config.cpp").c_str());
    const std::regex pattern(R"DELIM(string_restricted_f\s*\(\s*vars\s*,\s*"([^"]+)"\s*,\s*[^,]+,\s*\{([^}]*)\}\s*\))DELIM");

    for (std::sregex_iterator iter(content.begin(), content.end(), pattern), end; iter != end; ++iter) {
      const std::string name = (*iter)[1].str();
      const std::string body = (*iter)[2].str();

      std::vector<std::string> values;
      const std::regex valuePattern(R"DELIM("([^"]+)")DELIM");
      for (std::sregex_iterator valIter(body.begin(), body.end(), valuePattern), valEnd; valIter != valEnd; ++valIter) {
        values.push_back((*valIter)[1].str());
      }

      if (!values.empty()) {
        options[name] = values;
      }
    }

    return options;
  }

  // ---------------------------------------------------------------------
  // Web UI (config.html + configs/tabs/**/*.vue) vs config_schema.json drift guard.
  //
  // Re-armed from the old dead config.html-vs-docs/configuration.md parity gate (formerly
  // AllConfigOptionsExistInAllFiles / ConfigTabsMatchDocumentationSections, GTEST_SKIP'd once
  // docs/configuration.md was deleted in the macOS-only strip -- see hunt-config.md §3/§5 item 2
  // and design-modernization.md item A). config_schema.json is now the SSOT
  // (docs/design/config-schema-ssot.md); the web UI is a frozen, hand-maintained, break-glass
  // remote-admin surface (KEEP-and-freeze decision, not a rebuild target) that has not been
  // touched since the initial release, so it is a THIRD hand-maintained copy that can silently
  // drift from the schema with nothing to catch it. This guard closes that gap without removing
  // the duplication (removal = stage-4 web-UI rewrite, explicitly out of scope / NO-GO).
  //
  // Direction matters: these tests only assert web options are a SUBSET of the schema (the
  // schema is the superset SSOT). They do NOT assert the reverse (every schema option must
  // appear in the web UI) -- the web UI is intentionally frozen and is not expected to expose
  // every option the native Swift menubar app or config.cpp know about.
  // ---------------------------------------------------------------------

  static constexpr std::string_view kVueTabsDir = "src_assets/common/assets/web/configs/tabs";

  // Recursively list every *.vue file under configs/tabs/ -- not just the 7 top-level tab
  // components, but also the nested helper components under audiovideo/ and encoders/, any of
  // which may bind config.* fields via v-model.
  static std::vector<std::filesystem::path> listVueTabFiles() {
    std::vector<std::filesystem::path> files;
    const auto dir = sourceDir() / kVueTabsDir;
    if (!std::filesystem::exists(dir)) {
      return files;
    }

    for (const auto &entry : std::filesystem::recursive_directory_iterator(dir)) {
      if (entry.is_regular_file() && entry.path().extension() == ".vue") {
        files.push_back(entry.path());
      }
    }

    return files;
  }

  // Extract every `v-model="config.NAME"` binding across all configs/tabs/**/*.vue files -- the
  // .vue-side complement to extractConfigHtmlOptions() above (config.html's tabs[].options only
  // carries *default values*, it is not guaranteed to be a 1:1 list of everything the components
  // actually bind/render).
  static std::set<std::string, std::less<>> extractVueConfigModelNames() {
    std::set<std::string, std::less<>> names;
    const std::regex pattern(R"DELIM(v-model="config\.([a-zA-Z0-9_]+)")DELIM");

    for (const auto &file : listVueTabFiles()) {
      const std::string content = file_handler::read_file(file.string().c_str());
      for (std::sregex_iterator iter(content.begin(), content.end(), pattern), end; iter != end; ++iter) {
        names.insert((*iter)[1].str());
      }
    }

    return names;
  }

  // Extract literal <option value="..."> enum choices for every <select ... v-model=
  // "config.NAME"> block across all configs/tabs/**/*.vue files, keyed by option name. Values
  // nested inside <PlatformLayout> per-platform <template> slots (e.g. "capture"/"encoder") are
  // still plain literal <option> tags in the source text and are picked up the same as
  // unconditional ones -- platform gating only affects what renders at runtime, not what's in the
  // file. The empty-string "autodetect" placeholder value is dropped; it isn't a schema enum
  // member and every schema-side enum-typed option already carries its real default separately.
  static std::map<std::string, std::vector<std::string>, std::less<>> extractVueSelectEnumsByName() {
    std::map<std::string, std::vector<std::string>, std::less<>> result;
    const std::regex selectPattern(R"DELIM(<select[^>]*v-model="config\.([a-zA-Z0-9_]+)"[^>]*>([\s\S]*?)</select>)DELIM");
    const std::regex optionPattern(R"DELIM(<option\s+value="([^"]*)")DELIM");

    for (const auto &file : listVueTabFiles()) {
      const std::string content = file_handler::read_file(file.string().c_str());

      for (std::sregex_iterator iter(content.begin(), content.end(), selectPattern), end; iter != end; ++iter) {
        const std::string name = (*iter)[1].str();
        const std::string body = (*iter)[2].str();
        auto &values = result[name];

        for (std::sregex_iterator optIter(body.begin(), body.end(), optionPattern), optEnd; optIter != optEnd; ++optIter) {
          std::string value = (*optIter)[1].str();
          if (!value.empty()) {
            values.push_back(value);
          }
        }
      }
    }

    return result;
  }

  // Union of config.html's tabs[].options keys and every .vue v-model="config.*" binding --
  // "every option name the web UI references" -- the left-hand side of the web-subset-of-schema
  // assertion.
  static std::set<std::string, std::less<>> extractAllWebUiOptionNames() {
    std::set<std::string, std::less<>> names;

    for (const auto &[name, tabId] : extractConfigHtmlOptions()) {
      names.insert(name);
    }
    for (const auto &name : extractVueConfigModelNames()) {
      names.insert(name);
    }

    return names;
  }

  // Explicit, commented allowlist of web-UI-referenced names that are legitimately NOT expected
  // to exist in config_schema.json. Kept narrow and documented per-entry rather than loosening
  // the subset assertion itself (per this test's design brief).
  static const std::set<std::string, std::less<>> &webOnlySchemaAllowlist() {
    static const std::set<std::string, std::less<>> allowlist = {
      // Dead option: removed from config.cpp's apply_config() parsing AND from
      // config_schema.json as "wave-A item 10", a leftover of the deleted inputtino gamepad
      // backend (see the inline comment beside the ds5_inputtino_randomize_mac removal in
      // src/config.cpp's input-parsing block, ~line 1244). config.html and Inputs.vue still
      // declare/bind it, but it no longer round-trips through saveConfig's schema validation.
      // This is a documented, intentional leftover -- not silent drift -- so it's allowlisted
      // rather than causing this guard to fail on something already tracked elsewhere.
      "ds5_inputtino_randomize_mac",
      // NOT real config option names: these are the nested JSON-literal keys inside
      // dd_mode_remapping's default value in config.html
      // (`"dd_mode_remapping": {"mixed": [], "resolution_only": [], "refresh_rate_only": []}`).
      // extractConfigHtmlOptions()'s option-key regex is not nesting-aware and also matches keys
      // of nested object literals as if they were sibling top-level option names.
      // dd_mode_remapping itself IS a real schema option and is unaffected by this entry.
      "mixed",
      "resolution_only",
      "refresh_rate_only",
    };
    return allowlist;
  }
};

TEST_F(ConfigConsistencyTest, WebUiOptionsExistInSchema) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaNames = extractSchemaOptionNames(*schema);
  const auto webNames = extractAllWebUiOptionNames();
  const auto &allowlist = webOnlySchemaAllowlist();

  std::vector<std::string> driftedOptions;
  for (const auto &name : webNames) {
    if (allowlist.contains(name)) {
      continue;
    }
    if (!schemaNames.contains(name)) {
      driftedOptions.push_back(name);
    }
  }

  if (!driftedOptions.empty()) {
    std::string errorMsg =
      "config.html / configs/tabs/**/*.vue reference option names missing from "
      "config_schema.json -- the web UI has drifted from the schema SSOT "
      "(docs/design/config-schema-ssot.md). If this is a legitimate UI-only pseudo-field, "
      "add it (with a comment explaining why) to webOnlySchemaAllowlist() instead of "
      "loosening this assertion:\n";
    for (const auto &name : driftedOptions) {
      errorMsg += std::format("  {}\n", name);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, WebUiTabsMatchSchemaTabs) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  std::map<std::string, std::string, std::less<>> schemaTabByName;
  if (schema->contains("options") && (*schema)["options"].is_array()) {
    for (const auto &opt : (*schema)["options"]) {
      if (opt.contains("name") && opt["name"].is_string() && opt.contains("tab") && opt["tab"].is_string()) {
        schemaTabByName[opt["name"].get<std::string>()] = opt["tab"].get<std::string>();
      }
    }
  }

  const auto htmlOptions = extractConfigHtmlOptions();  // name -> config.html tab id
  const auto &allowlist = webOnlySchemaAllowlist();

  std::vector<std::string> mismatches;
  for (const auto &[name, htmlTabId] : htmlOptions) {
    if (allowlist.contains(name)) {
      continue;
    }

    const auto it = schemaTabByName.find(name);
    if (it == schemaTabByName.end()) {
      continue;  // Already reported by WebUiOptionsExistInSchema.
    }

    if (it->second != htmlTabId) {
      mismatches.push_back(std::format("{}: config.html places it in tab '{}' but schema says tab '{}'", name, htmlTabId, it->second));
    }
  }

  if (!mismatches.empty()) {
    std::string errorMsg = "config.html tab placement disagrees with config_schema.json's \"tab\" field:\n";
    for (const auto &mismatch : mismatches) {
      errorMsg += std::format("  {}\n", mismatch);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, WebUiVueSelectEnumsAreSubsetOfSchemaEnums) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaOptions = extractSchemaOptions(*schema);
  const auto vueEnums = extractVueSelectEnumsByName();
  const auto &allowlist = webOnlySchemaAllowlist();

  std::vector<std::string> mismatches;
  for (const auto &[name, vueValues] : vueEnums) {
    if (allowlist.contains(name)) {
      continue;
    }

    const auto it = schemaOptions.find(name);
    if (it == schemaOptions.end()) {
      continue;  // Already reported by WebUiOptionsExistInSchema.
    }

    if (!it->second.hasEnum) {
      // Schema declares no enum constraint for this option -- either an int range (e.g.
      // hevc_mode/av1_mode/lan_encryption_mode, checked numerically by the existing
      // schema<->config.cpp gate above) or a deliberately unconstrained / platform-populated
      // string (capture, encoder, gamepad, amd_usage, sw_preset, ... -- see hunt-config.md's
      // "dynamic enum" note). Any web-declared literal is vacuously a subset of an unconstrained
      // superset, so there's nothing to assert for this option.
      continue;
    }

    const std::set<std::string, std::less<>> schemaSet(it->second.enumValues.begin(), it->second.enumValues.end());
    std::vector<std::string> extra;
    for (const auto &value : vueValues) {
      if (!schemaSet.contains(value)) {
        extra.push_back(value);
      }
    }

    if (!extra.empty()) {
      mismatches.push_back(std::format(
        "{}: configs/tabs/**/*.vue <option> values [{}] are not all in schema constraints.enum [{}]",
        name,
        buildCommaSeparatedString(extra),
        buildCommaSeparatedString(it->second.enumValues)
      ));
    }
  }

  if (!mismatches.empty()) {
    std::string errorMsg = "Web UI <select> enum values have drifted beyond config_schema.json's constraints.enum:\n";
    for (const auto &mismatch : mismatches) {
      errorMsg += std::format("  {}\n", mismatch);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, ConfigOptionsInSameOrderWithinSections) {
  // Extract options with order preserved
  auto htmlOptionsByTab = extractConfigHtmlOptionsWithOrder();
  auto mdOptionsBySection = extractConfigMdOptionsWithOrder();

  std::vector<std::string> orderInconsistencies;

  // Compare order for each tab/section pair
  for (const auto &[docSection, tabId] : expectedDocToTabMapping) {
    if (!htmlOptionsByTab.contains(tabId) || !mdOptionsBySection.contains(docSection)) {
      continue;  // Skip if either tab or section doesn't exist
    }

    const auto &htmlOrder = htmlOptionsByTab.at(tabId);
    const auto &mdOrder = mdOptionsBySection.at(docSection);

    // Find options that exist in both HTML and MD for this section
    std::vector<std::string> commonOptions;
    for (const auto &option : htmlOrder) {
      if (std::ranges::find(mdOrder, option) != mdOrder.end()) {
        commonOptions.push_back(option);
      }
    }

    // Filter MD order to only include common options in the same order they appear in MD
    std::vector<std::string> mdOrderFiltered;
    for (const auto &option : mdOrder) {
      if (std::ranges::find(commonOptions, option) != commonOptions.end()) {
        mdOrderFiltered.push_back(option);
      }
    }

    // Compare the order of common options
    if (commonOptions != mdOrderFiltered && !commonOptions.empty() && !mdOrderFiltered.empty()) {
      // Create readable string representations of the option lists
      std::string htmlOrderStr = buildCommaSeparatedString(commonOptions);
      std::string mdOrderStr = buildCommaSeparatedString(mdOrderFiltered);

      std::string detailMsg = std::format(
        "Section '{}' (tab '{}') has different option order:\n"
        "  HTML order: [{}]\n"
        "  MD order:   [{}]",
        docSection,
        tabId,
        htmlOrderStr,
        mdOrderStr
      );
      orderInconsistencies.push_back(detailMsg);
    }
  }

  if (!orderInconsistencies.empty()) {
    std::string errorMsg = "Config option order inconsistencies:\n";
    for (const auto &inconsistency : orderInconsistencies) {
      errorMsg += std::format("  {}\n", inconsistency);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, DummyConfigOptionsDoNotExist) {
  const auto cppOptions = extractConfigCppOptions();
  const auto htmlOptions = extractConfigHtmlOptions();
  const auto mdOptions = extractConfigMdOptions();
  const auto jsonOptions = extractEnJsonConfigOptions();

  // List of fake config options that should NOT exist in any files
  const std::vector<std::string> dummyOptions = {
    "dummy_config_option",
    "nonexistent_setting",
    "fake_config_parameter",
    "test_dummy_option",
    "invalid_config_key"
  };

  std::vector<std::string> unexpectedlyFound;

  // Check that none of the fake options exist in any of the config files
  for (const auto &dummyOption : dummyOptions) {
    if (cppOptions.contains(dummyOption)) {
      unexpectedlyFound.push_back(std::format("config.cpp contains dummy option: {}", dummyOption));
    }

    if (htmlOptions.contains(dummyOption)) {
      unexpectedlyFound.push_back(std::format("config.html contains dummy option: {}", dummyOption));
    }

    if (mdOptions.contains(dummyOption)) {
      unexpectedlyFound.push_back(std::format("configuration.md contains dummy option: {}", dummyOption));
    }

    if (jsonOptions.contains(dummyOption)) {
      unexpectedlyFound.push_back(std::format("en.json contains dummy option: {}", dummyOption));
    }
  }

  // This test should pass (i.e., no fake options should be found)
  // If any fake options are found, it indicates a problem with the test data
  if (!unexpectedlyFound.empty()) {
    std::string errorMsg = "Dummy config options unexpectedly found in files:\n";
    for (const auto &found : unexpectedlyFound) {
      errorMsg += std::format("  {}\n", found);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, TestFrameworkDetectsMissingOptions) {
  const auto cppOptions = extractConfigCppOptions();
  const auto htmlOptions = extractConfigHtmlOptions();
  const auto mdOptions = extractConfigMdOptions();
  const auto jsonOptions = extractEnJsonConfigOptions();

  // Add a fake option to the cpp options to simulate a missing option scenario
  std::set<std::string, std::less<>> modifiedCppOptions = cppOptions;
  const std::string testDummyOption = "test_framework_validation_option";
  modifiedCppOptions.insert(testDummyOption);

  // Options that are internal/special and shouldn't be in UI/docs
  std::set<std::string, std::less<>> internalOptions = {
    "flags"  // Internal config flags, not user-configurable
  };

  std::vector<std::string> missingFromFiles;

  // Check that the fake option is detected as missing from other files
  for (const auto &option : modifiedCppOptions) {
    if (internalOptions.contains(option)) {
      continue;  // Skip internal options
    }

    if (!htmlOptions.contains(option)) {
      missingFromFiles.push_back(std::format("config.html missing: {}", option));
    }

    if (!mdOptions.contains(option)) {
      missingFromFiles.push_back(std::format("configuration.md missing: {}", option));
    }

    if (!jsonOptions.contains(option)) {
      missingFromFiles.push_back(std::format("en.json missing: {}", option));
    }
  }

  // Verify that the test framework detected the missing fake option
  bool foundMissingDummyInHtml = false;
  bool foundMissingDummyInMd = false;
  bool foundMissingDummyInJson = false;

  checkTestDummyDetection(missingFromFiles, testDummyOption, foundMissingDummyInHtml, foundMissingDummyInMd, foundMissingDummyInJson);

  // The test framework should have detected the fake option as missing from all files
  EXPECT_TRUE(foundMissingDummyInHtml) << "Test framework failed to detect missing option in config.html";
  EXPECT_TRUE(foundMissingDummyInMd) << "Test framework failed to detect missing option in configuration.md";
  EXPECT_TRUE(foundMissingDummyInJson) << "Test framework failed to detect missing option in en.json";

  // Verify we have at least 3 missing entries (one for each file type)
  EXPECT_GE(missingFromFiles.size(), 3) << "Test framework should detect missing dummy option in all three file types";
}

// ---------------------------------------------------------------------------
// config_schema.json parity gate (docs/design/config-schema-ssot.md, stages 1-2)
//
// Unlike the docs/configuration.md-era tests above, these are NOT allowed to GTEST_SKIP on a
// missing schema file: config_schema.json is committed alongside config.cpp as the schema's
// source of truth, so its absence is a real regression that must fail CI, not a stale-doc
// situation to tolerate.
// ---------------------------------------------------------------------------

TEST_F(ConfigConsistencyTest, ConfigSchemaFileExistsAndParses) {
  ASSERT_TRUE(std::filesystem::exists(schemaAbsolutePath()))
    << "config_schema.json is missing at " << schemaAbsolutePath()
    << " -- it is the SSOT for config option metadata (docs/design/config-schema-ssot.md) and must be committed, not generated.";

  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json exists but failed to parse as JSON";
  ASSERT_TRUE(schema->contains("options") && (*schema)["options"].is_array()) << "config_schema.json is missing a top-level \"options\" array";
  EXPECT_GT((*schema)["options"].size(), 0u) << "config_schema.json's options[] array is empty";
}

TEST_F(ConfigConsistencyTest, SchemaOptionsAreAllParsedByConfigCpp) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaNames = extractSchemaOptionNames(*schema);
  const auto cppOptions = extractConfigCppOptions();

  std::vector<std::string> orphanSchemaOptions;
  for (const auto &name : schemaNames) {
    if (!cppOptions.contains(name)) {
      orphanSchemaOptions.push_back(name);
    }
  }

  if (!orphanSchemaOptions.empty()) {
    std::string errorMsg = "config_schema.json declares options that config.cpp's apply_config() never parses:\n";
    for (const auto &name : orphanSchemaOptions) {
      errorMsg += std::format("  {}\n", name);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, AllConfigCppOptionsExistInSchema) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaNames = extractSchemaOptionNames(*schema);
  const auto cppOptions = extractConfigCppOptions();

  std::vector<std::string> undocumentedOptions;
  for (const auto &option : cppOptions) {
    if (!schemaNames.contains(option)) {
      undocumentedOptions.push_back(option);
    }
  }

  if (!undocumentedOptions.empty()) {
    std::string errorMsg = "config.cpp's apply_config() parses options that are missing from config_schema.json:\n";
    for (const auto &option : undocumentedOptions) {
      errorMsg += std::format("  {}\n", option);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, SchemaBoolTypeMatchesConfigCppBoolF) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaOptions = extractSchemaOptions(*schema);
  const auto boolOptions = extractConfigCppBoolOptions();

  std::vector<std::string> mismatches;
  for (const auto &name : boolOptions) {
    const auto it = schemaOptions.find(name);
    if (it == schemaOptions.end()) {
      // Already reported by AllConfigCppOptionsExistInSchema; don't double-report here.
      continue;
    }
    if (it->second.type != "bool") {
      mismatches.push_back(std::format("{}: config.cpp uses bool_f (expected schema type \"bool\") but schema says \"{}\"", name, it->second.type));
    }
  }

  if (!mismatches.empty()) {
    std::string errorMsg = "Schema type mismatches for bool_f-parsed options:\n";
    for (const auto &mismatch : mismatches) {
      errorMsg += std::format("  {}\n", mismatch);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, SchemaRangeMatchesConfigCppBetweenF) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaOptions = extractSchemaOptions(*schema);

  auto checkRanges = [&](const std::map<std::string, SchemaOption, std::less<>> &parserRanges, const std::string &helperName, std::vector<std::string> &mismatches) {
    for (const auto &[name, parserRange] : parserRanges) {
      const auto it = schemaOptions.find(name);
      if (it == schemaOptions.end()) {
        continue;  // Already reported by AllConfigCppOptionsExistInSchema.
      }

      if (!it->second.hasRange) {
        mismatches.push_back(std::format("{}: config.cpp uses {} with a range but schema has no constraints.min/max", name, helperName));
        continue;
      }

      // Only assert on bounds the regex could actually resolve to a literal integer -- symbolic
      // bounds (std::numeric_limits<T>::max(), the computed port range) are left unset by the
      // extractor and intentionally skipped here (see extractBetweenOptions' doc comment).
      if (parserRange.min.has_value()) {
        if (!it->second.min.has_value() || *it->second.min != *parserRange.min) {
          mismatches.push_back(std::format("{}: config.cpp min={} but schema constraints.min={}", name, *parserRange.min, it->second.min.has_value() ? std::to_string(*it->second.min) : "null"));
        }
      }
      if (parserRange.max.has_value()) {
        if (!it->second.max.has_value() || *it->second.max != *parserRange.max) {
          mismatches.push_back(std::format("{}: config.cpp max={} but schema constraints.max={}", name, *parserRange.max, it->second.max.has_value() ? std::to_string(*it->second.max) : "null"));
        }
      }
    }
  };

  std::vector<std::string> mismatches;
  checkRanges(extractConfigCppIntBetweenOptions(), "int_between_f", mismatches);
  checkRanges(extractConfigCppDoubleBetweenOptions(), "double_between_f", mismatches);

  if (!mismatches.empty()) {
    std::string errorMsg = "Schema range mismatches for *_between_f-parsed options:\n";
    for (const auto &mismatch : mismatches) {
      errorMsg += std::format("  {}\n", mismatch);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, SchemaEnumMatchesConfigCppStringRestrictedF) {
  const auto schema = loadConfigSchema();
  ASSERT_TRUE(schema.has_value()) << "config_schema.json missing or invalid -- see ConfigSchemaFileExistsAndParses";

  const auto schemaOptions = extractSchemaOptions(*schema);
  const auto parserEnums = extractConfigCppStringRestrictedEnums();

  std::vector<std::string> mismatches;
  for (const auto &[name, parserValues] : parserEnums) {
    const auto it = schemaOptions.find(name);
    if (it == schemaOptions.end()) {
      continue;  // Already reported by AllConfigCppOptionsExistInSchema.
    }

    if (!it->second.hasEnum) {
      mismatches.push_back(std::format("{}: config.cpp's string_restricted_f allow-list is [{}] but schema has no constraints.enum", name, buildCommaSeparatedString(parserValues)));
      continue;
    }

    std::set<std::string, std::less<>> parserSet(parserValues.begin(), parserValues.end());
    std::set<std::string, std::less<>> schemaSet(it->second.enumValues.begin(), it->second.enumValues.end());

    if (parserSet != schemaSet) {
      mismatches.push_back(std::format(
        "{}: config.cpp allow-list [{}] does not match schema constraints.enum [{}]",
        name,
        buildCommaSeparatedString(parserValues),
        buildCommaSeparatedString(it->second.enumValues)
      ));
    }
  }

  if (!mismatches.empty()) {
    std::string errorMsg = "Schema enum mismatches for string_restricted_f-parsed options:\n";
    for (const auto &mismatch : mismatches) {
      errorMsg += std::format("  {}\n", mismatch);
    }
    FAIL() << errorMsg;
  }
}

TEST_F(ConfigConsistencyTest, SchemaTestFrameworkDetectsInjectedOrphanOption) {
  // Sanity check that SchemaOptionsAreAllParsedByConfigCpp's detection logic actually works,
  // mirroring TestFrameworkDetectsMissingOptions above.
  auto cppOptions = extractConfigCppOptions();
  const std::string fakeOption = "schema_test_framework_orphan_option";
  ASSERT_FALSE(cppOptions.contains(fakeOption)) << "Test fixture bug: fake option collides with a real config.cpp option";

  std::set<std::string, std::less<>> schemaNamesWithFake = {fakeOption};
  bool detected = false;
  for (const auto &name : schemaNamesWithFake) {
    if (!cppOptions.contains(name)) {
      detected = true;
    }
  }
  EXPECT_TRUE(detected) << "Test framework failed to flag a schema option absent from config.cpp";
}
