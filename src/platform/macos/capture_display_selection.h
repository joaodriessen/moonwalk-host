#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace platf::macos {
  // Capture's actual selection contract; a current session VD always takes precedence.
  inline std::optional<uint32_t> select_capture_display(
    uint32_t virtual_id,
    uint32_t main_id,
    std::string_view requested,
    const std::vector<uint32_t> &active_ids
  ) {
    if (virtual_id != 0) {
      return virtual_id;
    }
    if (requested.empty()) {
      return main_id;
    }
    uint32_t id = 0;
    const auto parsed = std::from_chars(requested.data(), requested.data() + requested.size(), id);
    if (parsed.ec != std::errc() || parsed.ptr != requested.data() + requested.size() || id == 0 || std::find(active_ids.begin(), active_ids.end(), id) == active_ids.end()) {
      return std::nullopt;
    }
    return id;
  }
}  // namespace platf::macos
