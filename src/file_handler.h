/**
 * @file file_handler.h
 * @brief Declarations for file handling functions.
 */
#pragma once

// standard includes
#include <string>

/**
 * @brief Responsible for file handling functions.
 */
namespace file_handler {
  /**
   * @brief Get the parent directory of a file or directory.
   * @param path The path of the file or directory.
   * @return The parent directory.
   * @examples
   * std::string parent_dir = get_parent_directory("path/to/file");
   * @examples_end
   */
  std::string get_parent_directory(const std::string &path);

  /**
   * @brief Make a directory.
   * @param path The path of the directory.
   * @return `true` on success, `false` on failure.
   * @examples
   * bool dir_created = make_directory("path/to/directory");
   * @examples_end
   */
  bool make_directory(const std::string &path);

  /**
   * @brief Read a file to string.
   * @param path The path of the file.
   * @return The contents of the file.
   * @examples
   * std::string contents = read_file("path/to/file");
   * @examples_end
   */
  std::string read_file(const char *path);

  /**
   * @brief Writes a file.
   * @param path The path of the file.
   * @param contents The contents to write.
   * @return ``0`` on success, ``-1`` on failure.
   * @examples
   * int write_status = write_file("path/to/file", "file contents");
   * @examples_end
   */
  int write_file(const char *path, const std::string_view &contents);

  /**
   * @brief Writes a file crash-atomically.
   * @details Writes `contents` to a temp file in the same directory as `path`, flushes it, then
   *          `rename()`s it over `path`. The rename is atomic on the same filesystem, so a crash
   *          or power loss at any point before it either leaves the original file completely
   *          untouched, or completely replaced -- `path` is never observed truncated or partially
   *          written. Use this instead of `write_file()` for files that must never be left corrupt
   *          (e.g. the host's own config), since `write_file()` truncates in place.
   * @param path The path of the file to write.
   * @param contents The contents to write.
   * @return `true` on success, `false` on failure (the original file, if any, is left untouched).
   * @examples
   * bool ok = write_file_atomic("path/to/file", "file contents");
   * @examples_end
   */
  bool write_file_atomic(const char *path, const std::string_view &contents);
}  // namespace file_handler
