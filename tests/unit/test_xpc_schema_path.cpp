#ifdef __APPLE__

#include <filesystem>

#include <gtest/gtest.h>

#include <src/platform/macos/xpc_control.h>

namespace fs = std::filesystem;

TEST(ConfigSchemaPath, InstalledBundlePrefersBundleResourceThenConfiguredPath) {
  const auto candidates = platf::macos::config_schema_candidates(
    fs::path {"/Applications/Skylight.app/Contents/Resources/Helpers/Skylight"},
    fs::path {"/tmp/skylight-assets/web/config_schema.json"});

  ASSERT_EQ(candidates.size(), 2u);
  EXPECT_EQ(candidates[0], fs::path {"/Applications/Skylight.app/Contents/Resources/config_schema.json"});
  EXPECT_EQ(candidates[1], fs::path {"/tmp/skylight-assets/web/config_schema.json"});
}

TEST(ConfigSchemaPath, NonBundleExecutableUsesOnlyConfiguredPath) {
  const auto candidates = platf::macos::config_schema_candidates(
    fs::path {"/Users/example/Projects/Skylight/build/sunshine"},
    fs::path {"/tmp/skylight-assets/web/config_schema.json"});

  ASSERT_EQ(candidates.size(), 1u);
  EXPECT_EQ(candidates[0], fs::path {"/tmp/skylight-assets/web/config_schema.json"});
}

TEST(ConfigSchemaPath, DuplicateConfiguredBundlePathIsReturnedOnce) {
  const fs::path bundled {"/Applications/Skylight.app/Contents/Resources/config_schema.json"};
  const auto candidates = platf::macos::config_schema_candidates(
    fs::path {"/Applications/Skylight.app/Contents/Resources/Helpers/Skylight"}, bundled);

  ASSERT_EQ(candidates.size(), 1u);
  EXPECT_EQ(candidates[0], bundled);
}

TEST(ConfigSchemaPath, ResourceHelperWalksUpToBundleContents) {
  const auto candidates = platf::macos::config_schema_candidates(
    fs::path {"/Applications/Skylight.app/Contents/Resources/Helpers/Skylight"},
    fs::path {"/tmp/skylight-assets/web/config_schema.json"});

  ASSERT_EQ(candidates.size(), 2u);
  EXPECT_EQ(candidates[0], fs::path {"/Applications/Skylight.app/Contents/Resources/config_schema.json"});
  EXPECT_EQ(candidates[1], fs::path {"/tmp/skylight-assets/web/config_schema.json"});
}

#endif
