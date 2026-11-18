#pragma once

#include <optional>
#include <string_view>

namespace streaming_options {
  // Optional launch extensions. Absence is represented by the caller's defaults.
  inline std::optional<int> desktop_scale(std::string_view value) {
    if (value == "auto") return 0;
    if (value == "1") return 1;
    if (value == "2") return 2;
    return std::nullopt;
  }

  inline std::optional<bool> adaptive_bitrate(std::string_view value) {
    if (value == "0") return false;
    if (value == "1") return true;
    return std::nullopt;
  }
}
