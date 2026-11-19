/**
 * @file file_handler.cpp
 * @brief Definitions for file handling functions.
 */

// standard includes
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <thread>
#ifndef _WIN32
  #include <fcntl.h>
  #include <sys/stat.h>
  #include <unistd.h>
#endif

// local includes
#include "file_handler.h"
#include "logging.h"

namespace file_handler {
  std::string get_parent_directory(const std::string &path) {
    // remove any trailing path separators
    std::string trimmed_path = path;
    while (!trimmed_path.empty() && trimmed_path.back() == '/') {
      trimmed_path.pop_back();
    }

    std::filesystem::path p(trimmed_path);
    return p.parent_path().string();
  }

  bool make_directory(const std::string &path) {
    // first, check if the directory already exists
    if (std::filesystem::exists(path)) {
      return true;
    }

    return std::filesystem::create_directories(path);
  }

  std::string read_file(const char *path) {
    if (!std::filesystem::exists(path)) {
      BOOST_LOG(debug) << "Missing file: " << path;
      return {};
    }

    std::ifstream in(path);
    return std::string {(std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()};
  }

  int write_file(const char *path, const std::string_view &contents) {
    std::ofstream out(path);

    if (!out.is_open()) {
      return -1;
    }

    out << contents;

    return 0;
  }

#ifndef _WIN32
  static bool write_private_temp(std::string &path, std::string_view contents) {
    const int fd = mkstemp(path.data());
    if (fd < 0) return false;
    FILE *file = nullptr;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fchmod(fd, S_IRUSR | S_IWUSR) == 0) {
      file = fdopen(fd, "wb");
    }
    bool written = false;
    if (file) {
      written = std::fwrite(contents.data(), 1, contents.size(), file) == contents.size() &&
                std::fflush(file) == 0 && fsync(fd) == 0;
      written = std::fclose(file) == 0 && written;
    } else {
      close(fd);
    }
    if (!written) unlink(path.c_str());
    return written;
  }
#endif

  bool write_file_atomic(const char *path, const std::string_view &contents, file_access access) {
    const std::filesystem::path target(path);
    std::error_code status_ec;
    const auto original_status = std::filesystem::status(target, status_ec);
    if (status_ec && status_ec != std::errc::no_such_file_or_directory) {
      return false;
    }
    const bool preserve_permissions = !status_ec && std::filesystem::exists(original_status);

    // Temp file lives in the SAME directory as the target so the rename() below stays on one
    // filesystem (a cross-filesystem rename is not atomic, and may even fail outright). The
    // suffix (high-resolution timestamp + this thread's id) is just collision-avoidance for
    // concurrent/reentrant callers writing the same target -- it is not a security boundary.
    const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto tid = std::hash<std::thread::id> {}(std::this_thread::get_id());
    std::string tmp = target.string() + ".tmp." + std::to_string(now) + "." + std::to_string(tid);

#ifndef _WIN32
    if (access == file_access::owner_only) {
      tmp = target.string() + ".tmp.XXXXXX";
      if (!write_private_temp(tmp, contents)) {
        BOOST_LOG(warning) << "write_file_atomic: could not write private temporary file for " << target;
        return false;
      }
    } else
#endif
    {
      std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
      if (!out.is_open()) {
        BOOST_LOG(warning) << "write_file_atomic: could not open temp file " << tmp;
        return false;
      }

      // Preserve a private config's mode before its contents reach the temporary file.
      if (preserve_permissions || access == file_access::owner_only) {
        std::error_code permission_ec;
        const auto permissions = access == file_access::owner_only
          ? std::filesystem::perms::owner_read | std::filesystem::perms::owner_write
          : original_status.permissions();
        std::filesystem::permissions(tmp, permissions, permission_ec);
        if (permission_ec) {
          out.close();
          std::error_code rm_ec;
          std::filesystem::remove(tmp, rm_ec);
          return false;
        }
      }
      out.write(contents.data(), static_cast<std::streamsize>(contents.size()));
      out.flush();
      if (!out) {
        BOOST_LOG(warning) << "write_file_atomic: failed writing temp file " << tmp;
        std::error_code rm_ec;
        std::filesystem::remove(tmp, rm_ec);
        return false;
      }
    }

    // Never partially applied: on any failure below, the original file at `target` (if it
    // existed) is left completely untouched -- rename() either fully lands or doesn't happen.
    std::error_code ec;
    std::filesystem::rename(tmp, target, ec);
    if (ec) {
      BOOST_LOG(warning) << "write_file_atomic: failed atomic rename to " << target << ": " << ec.message();
      std::error_code rm_ec;
      std::filesystem::remove(tmp, rm_ec);
      return false;
    }

    return true;
  }
}  // namespace file_handler
