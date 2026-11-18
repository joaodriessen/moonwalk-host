/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace platf {
  bool is_screen_capture_allowed();

  // Fresh (uncached) per-call Screen Recording permission check, for use right before a
  // launch/resume request would start capture. Unlike is_screen_capture_allowed() (a value
  // latched once at daemon startup by init()), this re-queries the OS every call so a grant
  // toggled after the daemon started is picked up on the very next launch/resume without a
  // daemon restart. This is read-only: only the explicit XPC permission action may prompt.
  bool preflight_screen_capture_access();
  // Read-only, never prompts or opens System Settings.
  bool preflight_accessibility_access();

  // Snapshot of the cursor currently displayed by macOS, including cursors set
  // by other apps. The PNG is populated only when requested after a hash change.
  struct cursor_image_t {
    std::uint64_t hash = 0;
    int hot_x = 0;
    int hot_y = 0;
    int point_width = 0;
    int point_height = 0;
    std::string png;
  };
  std::optional<cursor_image_t> capture_system_cursor(bool include_png);
}

namespace platf::macos {
  // Generation-scoped cleanup for a launch that has never started streaming.
  uint32_t pending_display_generation();
  void release_pending_display(uint32_t generation);
}

namespace dyn {
  typedef void (*apiproc)();

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
