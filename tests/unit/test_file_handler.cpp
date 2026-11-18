/**
 * @file tests/unit/test_file_handler.cpp
 * @brief Test src/file_handler.*.
 */
#include "../tests_common.h"

#include <filesystem>
#include <format>
#include <src/file_handler.h>

struct FileHandlerParentDirectoryTest: testing::TestWithParam<std::tuple<std::string, std::string>> {};

TEST_P(FileHandlerParentDirectoryTest, Run) {
  auto [input, expected] = GetParam();
  EXPECT_EQ(file_handler::get_parent_directory(input), expected);
}

INSTANTIATE_TEST_SUITE_P(
  FileHandlerTests,
  FileHandlerParentDirectoryTest,
  testing::Values(
    std::make_tuple("/path/to/file.txt", "/path/to"),
    std::make_tuple("/path/to/directory", "/path/to"),
    std::make_tuple("/path/to/directory/", "/path/to")
  )
);

struct FileHandlerMakeDirectoryTest: testing::TestWithParam<std::tuple<std::string, bool, bool>> {};

TEST_P(FileHandlerMakeDirectoryTest, Run) {
  auto [input, expected, remove] = GetParam();
  const std::string test_dir = platf::appdata().string() + "/tests/path/";
  input = test_dir + input;

  EXPECT_EQ(file_handler::make_directory(input), expected);
  EXPECT_TRUE(std::filesystem::exists(input));

  // remove test directory
  if (remove) {
    std::filesystem::remove_all(test_dir);
    EXPECT_FALSE(std::filesystem::exists(test_dir));
  }
}

INSTANTIATE_TEST_SUITE_P(
  FileHandlerTests,
  FileHandlerMakeDirectoryTest,
  testing::Values(
    std::make_tuple("dir_123", true, false),
    std::make_tuple("dir_123", true, true),
    std::make_tuple("dir_123/abc", true, false),
    std::make_tuple("dir_123/abc", true, true)
  )
);

struct FileHandlerTests: testing::TestWithParam<std::tuple<int, std::string>> {};

INSTANTIATE_TEST_SUITE_P(
  TestFiles,
  FileHandlerTests,
  testing::Values(
    std::make_tuple(0, ""),  // empty file
    std::make_tuple(1, "a"),  // single character
    std::make_tuple(2, "Mr. Blue Sky - Electric Light Orchestra"),  // single line
    std::make_tuple(3, R"(
Morning! Today's forecast calls for blue skies
The sun is shining in the sky
There ain't a cloud in sight
It's stopped raining
Everybody's in the play
And don't you know, it's a beautiful new day
Hey, hey, hey!
Running down the avenue
See how the sun shines brightly in the city
All the streets where once was pity
Mr. Blue Sky is living here today!
Hey, hey, hey!
    )")  // multi-line
  )
);

TEST_P(FileHandlerTests, WriteFileTest) {
  auto [fileNum, content] = GetParam();
  const std::string fileName = std::format("write_file_test_{}.txt", fileNum);
  EXPECT_EQ(file_handler::write_file(fileName.c_str(), content), 0);
}

TEST_P(FileHandlerTests, ReadFileTest) {
  auto [fileNum, content] = GetParam();
  const std::string fileName = std::format("write_file_test_{}.txt", fileNum);
  EXPECT_EQ(file_handler::read_file(fileName.c_str()), content);
}

TEST(FileHandlerTests, ReadMissingFileTest) {
  // read missing file
  EXPECT_EQ(file_handler::read_file("non-existing-file.txt"), "");
}

TEST_P(FileHandlerTests, WriteFileAtomicTest) {
  auto [fileNum, content] = GetParam();
  const std::string fileName = std::format("write_file_atomic_test_{}.txt", fileNum);
  EXPECT_TRUE(file_handler::write_file_atomic(fileName.c_str(), content));
  EXPECT_EQ(file_handler::read_file(fileName.c_str()), content);
  std::filesystem::remove(fileName);
}

TEST(FileHandlerTests, WriteFileAtomicReplacesExistingContent) {
  const std::string fileName = "write_file_atomic_replace_test.txt";

  ASSERT_TRUE(file_handler::write_file_atomic(fileName.c_str(), "a much longer original content string"));
  ASSERT_EQ(file_handler::read_file(fileName.c_str()), "a much longer original content string");

  // Overwrite with shorter content. An in-place truncating writer risks leaving stale trailing
  // bytes if interrupted between truncate and write; the atomic rename swaps the whole file, so
  // the result must be exactly (and only) the new content -- no leftover tail from the old write.
  EXPECT_TRUE(file_handler::write_file_atomic(fileName.c_str(), "short"));
  EXPECT_EQ(file_handler::read_file(fileName.c_str()), "short");

  std::filesystem::remove(fileName);
}

TEST(FileHandlerTests, WriteFileAtomicDoesNotClobberTargetOnFailure) {
  // Force the rename() step to fail (can't rename a file onto an existing directory) while the
  // temp-file write itself succeeds, and confirm the target is left completely untouched -- the
  // core crash-atomicity property: a failed/interrupted write must never leave the target
  // truncated, partially written, or otherwise altered.
  const std::string targetDir = "write_file_atomic_target_is_dir";
  std::filesystem::remove_all(targetDir);
  ASSERT_TRUE(std::filesystem::create_directory(targetDir));

  EXPECT_FALSE(file_handler::write_file_atomic(targetDir.c_str(), "should never land"));
  EXPECT_TRUE(std::filesystem::is_directory(targetDir)) << "target must be untouched on failure";

  // no leaked temp file should remain in the working directory
  for (const auto &entry : std::filesystem::directory_iterator(".")) {
    EXPECT_EQ(entry.path().filename().string().rfind(targetDir + ".tmp.", 0), std::string::npos)
      << "leftover temp file: " << entry.path();
  }

  std::filesystem::remove_all(targetDir);
}
