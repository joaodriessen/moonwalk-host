#pragma once
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <unordered_map>

namespace file_transfer {
  using args_t = std::unordered_map<std::string, std::string>;

  struct reply {
    int status = 200;
    std::string body;
    std::string type = "application/json";
  };

  class service {
  public:
    explicit service(std::filesystem::path home, std::chrono::seconds expiry = std::chrono::seconds(60));
    ~service();
    service(const service &) = delete;
    reply request(const std::string &owner, const args_t &args, const std::string &body = {}, const std::string &session_scope = {});
    static constexpr std::uint64_t max_file_bytes = 8ull * 1024 * 1024 * 1024;
    static constexpr std::size_t max_chunk_bytes = 1024 * 1024;

  private:
    struct impl;
    std::unique_ptr<impl> state;
  };
}  // namespace file_transfer
