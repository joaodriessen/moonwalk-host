#include "file_transfer.h"

#include <boost/property_tree/json_parser.hpp>
#include <condition_variable>
#include <fstream>
#include <map>
#include <mutex>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <sstream>
#include <thread>
#ifndef _WIN32
  #include <fcntl.h>
  #include <sys/stat.h>
  #include <unistd.h>
#endif

namespace file_transfer {
  namespace fs = std::filesystem;
  namespace pt = boost::property_tree;

  namespace {
    std::string json(const pt::ptree &tree) {
      std::ostringstream out;
      pt::write_json(out, tree, false);
      return out.str();
    }

    std::string arg(const args_t &args, const char *key, const std::string &fallback = {}) {
      auto it = args.find(key);
      return it == args.end() ? fallback : it->second;
    }

    std::string token() {
      unsigned char bytes[16];
      if (RAND_bytes(bytes, sizeof(bytes)) != 1) {
        throw std::runtime_error("Unable to create transfer ID");
      }
      const char *hex = "0123456789abcdef";
      std::string s;
      for (auto b : bytes) {
        s += hex[b >> 4];
        s += hex[b & 15];
      }
      return s;
    }

    std::uint64_t number(const std::string &s) {
      if (s.empty() || s.find_first_not_of("0123456789") != std::string::npos) {
        throw std::runtime_error("Invalid transfer size or offset");
      }
      std::size_t used;
      auto n = std::stoull(s, &used);
      if (used != s.size()) {
        throw std::runtime_error("Invalid transfer number");
      }
      return n;
    }

    struct destination_state {
      bool exists = false;
      std::uintmax_t size = 0;
      fs::file_time_type modified {};
#ifndef _WIN32
      dev_t device = 0;
      ino_t inode = 0;
#endif
      bool operator==(const destination_state &) const = default;
    };

    destination_state inspect_destination(const fs::path &path) {
      destination_state result;
      result.exists = fs::exists(path);
      if (!result.exists) {
        return result;
      }
      if (!fs::is_regular_file(path) || fs::is_symlink(path)) {
        throw std::runtime_error("Destination is no longer a regular file; original preserved");
      }
      result.size = fs::file_size(path);
      result.modified = fs::last_write_time(path);
#ifndef _WIN32
      struct stat status {};
      if (::stat(path.c_str(), &status) != 0) {
        throw std::runtime_error("Destination could not be checked; original preserved");
      }
      result.device = status.st_dev;
      result.inode = status.st_ino;
#endif
      return result;
    }

    struct digest {
      EVP_MD_CTX *ctx = EVP_MD_CTX_new();

      digest() {
        if (!ctx || EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) != 1) {
          throw std::runtime_error("Unable to initialize transfer checksum");
        }
      }

      ~digest() {
        EVP_MD_CTX_free(ctx);
      }

      void update(const std::string &bytes) {
        if (EVP_DigestUpdate(ctx, bytes.data(), bytes.size()) != 1) {
          throw std::runtime_error("Checksum failed");
        }
      }

      std::string finish() {
        unsigned char bytes[EVP_MAX_MD_SIZE];
        unsigned n = 0;
        if (EVP_DigestFinal_ex(ctx, bytes, &n) != 1) {
          throw std::runtime_error("Checksum failed");
        }
        const char *hex = "0123456789abcdef";
        std::string s;
        for (unsigned i = 0; i < n; ++i) {
          s += hex[bytes[i] >> 4];
          s += hex[bytes[i] & 15];
        }
        return s;
      }
    };
  }  // namespace

  struct service::impl {
    struct transfer {
      std::string owner, id, expected, session_scope;
      destination_state original;
      fs::path path, temp;
      bool upload = false, overwrite = false;
      std::uint64_t size = 0, offset = 0;
      fs::file_time_type modified;
      std::fstream file;
      digest hash;
      std::chrono::steady_clock::time_point touched = std::chrono::steady_clock::now();

      ~transfer() {
        file.close();
        if (!temp.empty()) {
          std::error_code ignored;
          fs::remove(temp, ignored);
        }
      }
    };

    fs::path home;
    std::chrono::seconds expiry;
    std::mutex mutex;
    std::condition_variable wake;
    bool stop = false;
    std::map<std::string, std::unique_ptr<transfer>> transfers;
    std::thread reaper;

    impl(fs::path h, std::chrono::seconds e):
        home(std::move(h)),
        expiry(e),
        reaper([this] {
          std::unique_lock lock(mutex);
          while (!stop) {
            wake.wait_for(lock, std::chrono::seconds(1));
            auto now = std::chrono::steady_clock::now();
            for (auto it = transfers.begin(); it != transfers.end();) {
              if (now - it->second->touched >= expiry) {
                it = transfers.erase(it);
              } else {
                ++it;
              }
            }
          }
        }) {}

    ~impl() {
      {
        std::lock_guard lock(mutex);
        stop = true;
        wake.notify_all();
      }
      reaper.join();
    }

    fs::path resolve(const std::string &folder, const std::string &relative) {
      if (!home.is_absolute()) {
        throw std::runtime_error("User home folder is unavailable");
      }
      if (folder != "Downloads" && folder != "Documents" && folder != "Desktop") {
        throw std::runtime_error("Choose Downloads, Documents or Desktop");
      }
      fs::path rel(relative);
      if (rel.is_absolute()) {
        throw std::runtime_error("Choose a relative path inside the selected folder");
      }
      for (const auto &part : rel) {
        if (part == "..") {
          throw std::runtime_error("Path leaves the selected folder");
        }
      }
      const auto root = fs::canonical(home / folder);
      const auto path = fs::weakly_canonical(root / rel);
      auto r = root.begin(), p = path.begin();
      for (; r != root.end(); ++r, ++p) {
        if (p == path.end() || *p != *r) {
          throw std::runtime_error("Path leaves the selected folder");
        }
      }
      return path;
    }
  };

  service::service(fs::path home, std::chrono::seconds expiry):
      state(std::make_unique<impl>(std::move(home), expiry)) {}

  service::~service() = default;

  reply service::request(const std::string &owner, const args_t &args, const std::string &body, const std::string &session_scope) {
    std::lock_guard lock(state->mutex);
    std::string current_id;
    try {
      if (owner.empty()) {
        return {403, "Authenticated device required", "text/plain"};
      }
      const auto op = arg(args, "op");
      if (op == "list") {
        auto path = state->resolve(arg(args, "folder"), arg(args, "path"));
        if (!fs::is_directory(path)) {
          throw std::runtime_error("Selected folder is unavailable");
        }
        pt::ptree result, entries;
        unsigned count = 0;
        for (const auto &entry : fs::directory_iterator(path)) {
          if (++count > 2000) {
            throw std::runtime_error("Folder has too many entries; choose a smaller folder");
          }
          if (entry.path().filename().string().rfind(".skylight-", 0) == 0 || entry.is_symlink()) {
            continue;
          }
          if (!entry.is_directory() && !entry.is_regular_file()) {
            continue;
          }
          pt::ptree e;
          e.put("name", entry.path().filename().string());
          e.put("isDirectory", entry.is_directory());
          e.put("size", entry.is_regular_file() ? entry.file_size() : 0);
          e.put("relativePath", (fs::path(arg(args, "path")) / entry.path().filename()).generic_string());
          entries.push_back({"", e});
        }
        result.add_child("entries", entries);
        return {200, json(result)};
      }
      if (op == "beginUpload" || op == "beginDownload") {
        if (state->transfers.size() >= 8) {
          return {503, "Too many active transfers; cancel one or retry", "text/plain"};
        }
        auto t = std::make_unique<impl::transfer>();
        t->id = token();
        t->owner = owner;
        t->session_scope = session_scope;
        t->upload = op == "beginUpload";
        if (t->upload) {
          const auto name = arg(args, "name");
          if (name.empty() || name == "." || name == ".." || name.find_first_of("/\\") != std::string::npos || name.find('\0') != std::string::npos) {
            throw std::runtime_error("Choose a regular file name");
          }
          const auto directory = state->resolve(arg(args, "folder"), arg(args, "path"));
          if (!fs::is_directory(directory)) {
            throw std::runtime_error("Destination folder is unavailable");
          }
          t->path = directory / fs::path(name);
          t->size = number(arg(args, "size"));
          t->expected = arg(args, "sha256");
          t->overwrite = arg(args, "overwrite", "0") == "1";
          if (t->expected.size() != 64 || t->expected.find_first_not_of("0123456789abcdef") != std::string::npos) {
            throw std::runtime_error("Invalid SHA-256 checksum");
          }
          if (fs::exists(t->path) && (!t->overwrite || !fs::is_regular_file(t->path) || fs::is_symlink(t->path))) {
            return {409, "Destination exists; choose a different name or explicitly replace the file", "text/plain"};
          }
          t->original = inspect_destination(t->path);
          t->temp = directory / (".skylight-" + t->id + ".part");
#ifndef _WIN32
          const int staging = ::open(t->temp.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
          if (staging < 0) {
            t->temp.clear();
            throw std::runtime_error("Unable to create transfer staging file");
          }
          ::close(staging);
#endif
          t->file.open(t->temp, std::ios::binary | std::ios::out | std::ios::trunc);
        } else {
          t->path = state->resolve(arg(args, "folder"), arg(args, "path"));
          if (!fs::is_regular_file(t->path)) {
            throw std::runtime_error("Only regular files can be transferred");
          }
          t->size = fs::file_size(t->path);
          t->modified = fs::last_write_time(t->path);
          t->file.open(t->path, std::ios::binary | std::ios::in);
        }
        if (t->size > max_file_bytes) {
          throw std::runtime_error("File exceeds the 8 GiB transfer limit");
        }
        if (!t->file) {
          throw std::runtime_error("Unable to open file; check folder permissions");
        }
        pt::ptree result;
        result.put("id", t->id);
        result.put("size", t->size);
        result.put("name", t->path.filename().string());
        result.put("chunkBytes", max_chunk_bytes);
        state->transfers.emplace(t->id, std::move(t));
        return {200, json(result)};
      }
      current_id = arg(args, "id");
      auto it = state->transfers.find(current_id);
      if (it == state->transfers.end()) {
        return {404, "Transfer expired or was canceled; start again", "text/plain"};
      }
      auto &t = *it->second;
      if (t.owner != owner) {
        return {403, "Transfer belongs to another device", "text/plain"};
      }
      t.touched = std::chrono::steady_clock::now();
      if (op == "cancel") {
        state->transfers.erase(it);
        return {200, "{}"};
      }
      if (t.session_scope != session_scope) {
        throw std::runtime_error("Streaming session changed; start the transfer again");
      }
      if (op == "chunk") {
        if (!t.upload || body.empty() || body.size() > max_chunk_bytes || number(arg(args, "offset")) != t.offset || t.offset + body.size() > t.size) {
          throw std::runtime_error("Invalid or out-of-order upload chunk");
        }
        t.file.write(body.data(), body.size());
        if (!t.file) {
          throw std::runtime_error("Destination write failed; original file is preserved");
        }
        t.hash.update(body);
        t.offset += body.size();
        return {200, "{}"};
      }
      if (op == "read") {
        if (t.upload || number(arg(args, "offset")) != t.offset || t.offset >= t.size) {
          throw std::runtime_error("Invalid or out-of-order download chunk");
        }
        std::string bytes(std::min<std::uint64_t>(max_chunk_bytes, t.size - t.offset), '\0');
        t.file.read(bytes.data(), bytes.size());
        if (std::size_t(t.file.gcount()) != bytes.size()) {
          throw std::runtime_error("Source changed or could not be read; destination is preserved");
        }
        t.hash.update(bytes);
        t.offset += bytes.size();
        return {200, std::move(bytes), "application/octet-stream"};
      }
      if (op == "finish") {
        if (t.offset != t.size) {
          throw std::runtime_error("Transfer is incomplete; original file is preserved");
        }
        auto checksum = t.hash.finish();
        if (t.upload) {
          t.file.flush();
          if (!t.file || checksum != t.expected) {
            throw std::runtime_error("Transfer checksum failed; original file is preserved");
          }
          t.file.close();
          if (t.overwrite) {
            if (!(inspect_destination(t.path) == t.original)) {
              throw std::runtime_error("Destination changed during transfer; newer contents were preserved");
            }
            fs::rename(t.temp, t.path);
          } else {
#ifdef _WIN32
            if (fs::exists(t.path)) {
              throw std::runtime_error("Destination appeared during transfer; original preserved");
            }
            fs::rename(t.temp, t.path);
#else
            if (::link(t.temp.c_str(), t.path.c_str()) != 0) {
              throw std::runtime_error("Destination exists or cannot be published; original preserved");
            }
            fs::remove(t.temp);
#endif
          }
          t.temp.clear();
        } else if (fs::file_size(t.path) != t.size || fs::last_write_time(t.path) != t.modified) {
          throw std::runtime_error("Source changed during transfer; destination is preserved");
        }
        pt::ptree result;
        result.put("sha256", checksum);
        result.put("size", t.size);
        state->transfers.erase(it);
        return {200, json(result)};
      }
      throw std::runtime_error("Unknown file transfer action");
    } catch (const std::exception &error) {
      // A failed transaction cannot be resumed with an ambiguous hash/offset.
      if (!current_id.empty()) {
        auto it = state->transfers.find(current_id);
        if (it != state->transfers.end() && it->second->owner == owner) {
          state->transfers.erase(it);
        }
      }
      return {400, error.what(), "text/plain"};
    }
  }
}  // namespace file_transfer
