/**
 * @file src/protocol_parsing.h
 * @brief Bounded parsing shared by the receive callbacks and their unit tests.
 */
#pragma once

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string_view>

namespace rtsp_stream {
  // bytes contains the accumulated header; previous_size is its size before this read.
  inline std::size_t plaintext_header_end(std::string_view bytes, std::size_t previous_size) {
    constexpr std::string_view delimiter = "\r\n\r\n";
    if (previous_size > bytes.size()) {
      return std::string_view::npos;
    }
    // Revisit at most three old bytes: the delimiter may straddle any TCP read.
    auto start = previous_size - std::min(previous_size, delimiter.size() - 1);
    auto pos = bytes.find(delimiter, start);
    return pos == std::string_view::npos ? pos : pos + delimiter.size();
  }
}  // namespace rtsp_stream

namespace stream {
  struct encrypted_control_payload_t {
    std::uint32_t seq;
    std::string_view tagged_cipher;
  };

  // payload starts after the outer two-byte packet type, at the LE length and sequence.
  inline std::optional<encrypted_control_payload_t> parse_encrypted_control(std::string_view payload) {
    constexpr std::size_t header_size = sizeof(std::uint16_t) + sizeof(std::uint32_t);
    if (payload.size() < header_size) {
      return std::nullopt;
    }
    auto byte = [&](std::size_t offset) {
      return static_cast<std::uint8_t>(payload[offset]);
    };
    auto length = static_cast<std::uint16_t>(byte(0) | (std::uint16_t {byte(1)} << 8));
    // Length includes sequence, GCM tag and the encrypted four-byte control header.
    if (length < 4 + 16 + 4 || length - 4u > payload.size() - header_size) {
      return std::nullopt;
    }
    auto seq = std::uint32_t {byte(2)} | (std::uint32_t {byte(3)} << 8) |
               (std::uint32_t {byte(4)} << 16) | (std::uint32_t {byte(5)} << 24);
    return encrypted_control_payload_t {seq, payload.substr(header_size, length - 4u)};
  }
}  // namespace stream
