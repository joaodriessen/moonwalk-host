#ifdef __APPLE__

#include <filesystem>

#include <gtest/gtest.h>

#include <src/file_handler.h>
#include <src/platform/macos/xpc_control.h>

namespace fs = std::filesystem;

TEST(ConfigSchemaPath, RelocatedBundleUsesItsOwnResources) {
  const fs::path executable {"/Users/example/Applications/Tester Build.app/Contents/Resources/Helpers/Skylight"};
  const auto resources = file_handler::bundle_resources(executable);
  ASSERT_EQ(resources, fs::path {"/Users/example/Applications/Tester Build.app/Contents/Resources"});

  const auto candidates = platf::macos::config_schema_candidates(
    resources, fs::path {"/Applications/Skylight.app/Contents/Resources/assets/web/config_schema.json"});
  ASSERT_EQ(candidates.size(), 2u);
  EXPECT_EQ(candidates[0], resources / "config_schema.json");
  EXPECT_EQ(candidates[1], resources / "assets/web/config_schema.json");
}

TEST(ConfigSchemaPath, NonBundleExecutableUsesOnlyConfiguredPath) {
  const auto resources = file_handler::bundle_resources("/Users/example/Projects/Skylight/build/sunshine");
  EXPECT_TRUE(resources.empty());

  const fs::path configured {"/tmp/skylight-assets/web/config_schema.json"};
  const auto candidates = platf::macos::config_schema_candidates(resources, configured);
  ASSERT_EQ(candidates.size(), 1u);
  EXPECT_EQ(candidates[0], configured);
}

TEST(ConfigSchemaPath, NestedBundleUsesTheNearestResources) {
  const auto resources = file_handler::bundle_resources(
    "/Applications/Test.app/Contents/PlugIns/Embedded.app/Contents/MacOS/Embedded");
  EXPECT_EQ(resources, fs::path {"/Applications/Test.app/Contents/PlugIns/Embedded.app/Contents/Resources"});
}

#endif
