#pragma once
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace png_clipboard {
  constexpr std::size_t max_bytes = 4 * 1024 * 1024;

  inline bool valid_header(std::string_view bytes) {
    constexpr unsigned char signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (bytes.size() < 33 || bytes.size() > max_bytes) {
      return false;
    }
    for (unsigned n = 0; n < 8; ++n) {
      if (std::uint8_t(bytes[n]) != signature[n]) {
        return false;
      }
    }
    if (bytes.substr(8, 8) != std::string_view("\0\0\0\rIHDR", 8)) {
      return false;
    }
    auto u32 = [&](unsigned at) {
      std::uint32_t v = 0;
      for (unsigned n = 0; n < 4; ++n) {
        v = (v << 8) | std::uint8_t(bytes[at + n]);
      }
      return v;
    };
    const auto width = u32(16), height = u32(20);
    if (!width || !height || width > 4096 || height > 4096 || std::uint64_t(width) * height > 16 * 1024 * 1024) {
      return false;
    }
    bool have_idat = false, ended_idat = false;
    for (std::size_t at = 8; at < bytes.size();) {
      if (bytes.size() - at < 12) {
        return false;
      }
      const auto length = u32(unsigned(at));
      if (length > bytes.size() - at - 12) {
        return false;
      }
      const auto type = bytes.substr(at + 4, 4);
      if ((at == 8 && (type != "IHDR" || length != 13)) || (at != 8 && type == "IHDR")) {
        return false;
      }
      std::uint32_t crc = 0xffffffff;
      for (std::size_t n = at + 4; n < at + 8 + length; ++n) {
        crc ^= std::uint8_t(bytes[n]);
        for (unsigned bit = 0; bit < 8; ++bit) {
          crc = (crc >> 1) ^ ((0u - (crc & 1u)) & 0xedb88320u);
        }
      }
      if ((crc ^ 0xffffffffu) != u32(unsigned(at + 8 + length))) {
        return false;
      }
      if (type == "IDAT") {
        if (ended_idat) {
          return false;
        }
        have_idat = true;
      } else if (have_idat) {
        ended_idat = true;
      }
      const auto next = at + 12 + length;
      if (type == "IEND") {
        return length == 0 && have_idat && next == bytes.size();
      }
      at = next;
    }
    return false;
  }
}  // namespace png_clipboard
