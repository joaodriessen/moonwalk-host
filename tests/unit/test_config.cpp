/**
 * @file tests/unit/test_config.cpp
 * @brief Test src/config.cpp's config::to_bool().
 *
 * config::to_bool() is not declared in config.h (it's an internal helper used only by bool_f()),
 * but config.cpp is compiled directly into test_sunshine (see tests/CMakeLists.txt's
 * SUNSHINE_SOURCES glob), so a forward declaration here is enough for the linker to resolve it
 * against config.cpp's real definition -- no header change needed.
 */
#include "../tests_common.h"

#include <string>

namespace config {
  bool to_bool(std::string &boolean);
}

// ---------------------------------------------------------------------
// to_bool() -- case-insensitive matching (wave-A item 8)
//
// The original implementation ran std::for_each with a lambda that RETURNED std::tolower(ch)
// but never wrote the result back into the string -- so `boolean` was never actually
// lowercased, and any truthy value with non-lowercase letters (e.g. "TRUE", "Enabled") fell
// through to the "contains a '1'" fallback and was misread as false. Fixed with
// std::transform writing back into the string.
// ---------------------------------------------------------------------

TEST(ConfigToBool, LowercaseTrueIsTrue) {
  std::string s = "true";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, UppercaseTRUEIsTrue) {
  std::string s = "TRUE";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, MixedCaseEnabledIsTrue) {
  std::string s = "Enabled";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, MixedCaseYesIsTrue) {
  std::string s = "Yes";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, MixedCaseOnIsTrue) {
  std::string s = "On";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, MixedCaseEnableIsTrue) {
  std::string s = "Enable";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, FalseVocabularyIsFalse) {
  std::string s = "false";
  EXPECT_FALSE(config::to_bool(s));
  std::string s2 = "FALSE";
  EXPECT_FALSE(config::to_bool(s2));
  std::string s3 = "Disabled";
  EXPECT_FALSE(config::to_bool(s3));
  std::string s4 = "No";
  EXPECT_FALSE(config::to_bool(s4));
  std::string s5 = "Off";
  EXPECT_FALSE(config::to_bool(s5));
}

TEST(ConfigToBool, NumericOneIsTrue) {
  std::string s = "1";
  EXPECT_TRUE(config::to_bool(s));
}

TEST(ConfigToBool, NumericZeroIsFalse) {
  std::string s = "0";
  EXPECT_FALSE(config::to_bool(s));
}
