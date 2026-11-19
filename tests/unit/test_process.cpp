/**
 * @file tests/unit/test_process.cpp
 * @brief Test src/process.* functions.
 */
// test imports
#include "../tests_common.h"

// standard imports
#include <filesystem>
#include <fstream>

// lib includes
#include <boost/process/v1.hpp>

// local imports
#include <src/process.h>
#include <src/rtsp.h>

namespace fs = std::filesystem;

class ProcessPNGTest: public ::testing::Test {
protected:
  void SetUp() override {
    // Create test directory
    test_dir = fs::temp_directory_path() / "sunshine_process_png_test";
    fs::create_directories(test_dir);
  }

  void TearDown() override {
    // Clean up test directory
    if (fs::exists(test_dir)) {
      fs::remove_all(test_dir);
    }
  }

  // Helper function to create a file with specific content
  void createTestFile(const fs::path &path, const std::vector<unsigned char> &content) const {
    std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char *>(content.data()), content.size());
    file.close();
  }

  fs::path test_dir;
};

// Tests for check_valid_png function
TEST_F(ProcessPNGTest, CheckValidPNG_ValidSignature) {
  // Valid PNG signature
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,  // PNG signature
    // Add some dummy data to make it more realistic
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "valid.png";
  createTestFile(test_file, valid_png_data);

  EXPECT_TRUE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_WrongSignature) {
  // Invalid PNG signature (wrong magic bytes)
  const std::vector<unsigned char> invalid_png_data = {
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "invalid.png";
  createTestFile(test_file, invalid_png_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_TooShort) {
  // File too short (less than 8 bytes)
  const std::vector<unsigned char> short_data = {
    0x89,
    0x50,
    0x4E,
    0x47
  };

  const fs::path test_file = test_dir / "short.png";
  createTestFile(test_file, short_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_EmptyFile) {
  // Empty file
  const std::vector<unsigned char> empty_data = {};

  const fs::path test_file = test_dir / "empty.png";
  createTestFile(test_file, empty_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_NonExistentFile) {
  // File doesn't exist
  const fs::path test_file = test_dir / "nonexistent.png";

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_RealFile) {
  // Test with the actual sunshine.png from the project root

  // Only run this test if the file exists
  if (const fs::path sunshine_png = fs::path(SUNSHINE_SOURCE_DIR) / "sunshine.png"; fs::exists(sunshine_png)) {
    EXPECT_TRUE(proc::check_valid_png(sunshine_png));
  } else {
    GTEST_SKIP() << "sunshine.png not found in project root";
  }
}

TEST_F(ProcessPNGTest, CheckValidPNG_JPEGFile) {
  // JPEG signature (not PNG)
  const std::vector<unsigned char> jpeg_data = {
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46
  };

  const fs::path test_file = test_dir / "fake.png";
  createTestFile(test_file, jpeg_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_PartialSignature) {
  // Partial PNG signature (first 4 bytes correct, rest wrong)
  const std::vector<unsigned char> partial_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "partial.png";
  createTestFile(test_file, partial_png_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

// Tests for validate_app_image_path function
TEST_F(ProcessPNGTest, ValidateAppImagePath_EmptyPath) {
  // Empty path should return default
  const std::string result = proc::validate_app_image_path("");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_NonPNGExtension) {
  // Non-PNG extension should return default
  const std::string result = proc::validate_app_image_path("image.jpg");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_CaseInsensitiveExtension) {
  // Test that .PNG (uppercase) is recognized
  // Create a valid PNG file
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "test.PNG";
  createTestFile(test_file, valid_png_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  // Should accept uppercase .PNG extension
  EXPECT_NE(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_NonExistentFile) {
  // Non-existent PNG file should return default
  const std::string result = proc::validate_app_image_path("/nonexistent/path/image.png");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_InvalidPNGSignature) {
  // File with .png extension but invalid signature should return default
  const std::vector<unsigned char> invalid_data = {
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "invalid.png";
  createTestFile(test_file, invalid_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_ValidPNG) {
  // Valid PNG file should return the path
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "valid.png";
  createTestFile(test_file, valid_png_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  EXPECT_EQ(result, test_file.string());
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_OldSteamDefault) {
  // Test the special case for old steam image path
  const std::string result = proc::validate_app_image_path("./assets/steam.png");
  EXPECT_EQ(result, SUNSHINE_ASSETS_DIR "/steam.png");
}

// Regression LOCKS (not red-green -- see docs/superpowers/plans/2026-08-14-first-alpha-
// stabilization.md Task 4). These lock behavior the 2026-08-14 prep-cmd-failure dossier proved
// already correct: a failing prep_cmds[0].do_cmd makes execute() return non-zero, leaves
// proc_t retryable (running() == 0), and the undo loop only ever fires for cmds that actually
// succeeded (never for the failed cmd itself, never for cmds after it). Expected green on first
// run.
class ProcPrepCmdTest: public ::testing::Test {
protected:
  void SetUp() override {
    test_dir = fs::temp_directory_path() / "sunshine_prep_cmd_test";
    fs::create_directories(test_dir);
  }

  void TearDown() override {
    if (fs::exists(test_dir)) {
      fs::remove_all(test_dir);
    }
  }

  static std::shared_ptr<rtsp_stream::launch_session_t> make_session() {
    auto session = std::make_shared<rtsp_stream::launch_session_t>();
    session->width = 1920;
    session->height = 1080;
    session->fps = 60;
    return session;
  }

  fs::path test_dir;
};

TEST_F(ProcPrepCmdTest, ExecuteFailsAndStaysRetryable) {
  proc::ctx_t ctx;
  ctx.id = "1";
  ctx.name = "TestApp";
  ctx.prep_cmds.emplace_back(std::string {"/nonexistent-skylight-test/prep.sh"}, false);
  ctx.exit_timeout = std::chrono::seconds {5};

  std::vector<proc::ctx_t> apps {ctx};
  proc::proc_t test_proc {boost::this_process::environment(), std::move(apps)};

  const auto session = make_session();
  const int result = test_proc.execute(1, session);

  EXPECT_NE(result, 0) << "execute() must fail when the first prep-cmd's do_cmd is missing";
  EXPECT_EQ(test_proc.running(), 0) << "a failed launch must leave proc_t retryable (no stuck app_id)";
}

TEST_F(ProcPrepCmdTest, UndoRunsOnlyForSucceededCmds) {
  const fs::path marker = test_dir / "undo-ran.marker";

  proc::ctx_t ctx;
  ctx.id = "1";
  ctx.name = "TestApp";
  // First cmd succeeds; its undo touches the marker file.
  const std::string undo_cmd = "/bin/sh -c \"touch " + marker.string() + "\"";
  ctx.prep_cmds.emplace_back(std::string {"/usr/bin/true"}, std::string {undo_cmd}, false);
  // Second cmd is the one that fails -- execute() must return before ever appending an undo
  // for this cmd (it has none anyway; the point is the loop never reaches it as "succeeded").
  ctx.prep_cmds.emplace_back(std::string {"/nonexistent-skylight-test/prep.sh"}, false);
  ctx.exit_timeout = std::chrono::seconds {5};

  std::vector<proc::ctx_t> apps {ctx};
  proc::proc_t test_proc {boost::this_process::environment(), std::move(apps)};

  const auto session = make_session();
  const int result = test_proc.execute(1, session);

  EXPECT_NE(result, 0) << "execute() must fail when the second prep-cmd's do_cmd is missing";
  EXPECT_TRUE(fs::exists(marker)) << "the undo for the succeeded first cmd must have run";
  EXPECT_EQ(test_proc.running(), 0) << "a failed launch must leave proc_t retryable (no stuck app_id)";
}

TEST_F(ProcPrepCmdTest, RefreshApplicationsKeepsTheRunningTarget) {
  const auto path = (test_dir / "apps.json").string();
  auto cleanup = util::fail_guard([] {
    proc::proc.terminate();
    proc::proc = proc::proc_t {};
  });

  std::ofstream(path) << R"({"env": {}, "apps": [{"name": "First Desktop"}]})";
  proc::refresh(path);
  const auto original = proc::proc.get_apps();
  ASSERT_EQ(original.size(), 1);
  const auto running = std::stoi(original.front().id);
  ASSERT_EQ(proc::proc.execute(running, make_session()), 0);
  ASSERT_EQ(proc::current_target_id(), running);

  std::ofstream(path) << R"({"env": {}, "apps": [{"name": "Second Desktop"}]})";
  proc::refresh(path);

  const auto updated = proc::proc.get_apps();
  ASSERT_EQ(updated.size(), 1);
  EXPECT_EQ(updated.front().name, "Second Desktop");
  EXPECT_EQ(proc::current_target_id(), running);
  EXPECT_EQ(proc::proc.running(), running);
  EXPECT_EQ(proc::proc.get_last_run_app_name(), "First Desktop");

  proc::proc.terminate();
  EXPECT_EQ(proc::current_target_id(), 0);
  EXPECT_EQ(proc::proc.execute(std::stoi(updated.front().id), make_session()), 0);
  EXPECT_EQ(proc::proc.get_last_run_app_name(), "Second Desktop");
}
