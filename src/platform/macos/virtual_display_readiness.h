/**
 * @file src/platform/macos/virtual_display_readiness.h
 * @brief Shared readiness contract for publishing and capturing a virtual display.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

static inline bool skylight_virtual_display_ready(bool online, bool active, bool mirrored, uint32_t mirror_of, double width, double height) {
  return online && active && !mirrored && mirror_of == 0 && width > 1 && height > 1;
}

// The helper supplies a fresh readiness snapshot and a synchronous activation
// transaction. Keep this boundary testable without touching WindowServer.
static inline bool skylight_virtual_display_activate_if_needed(bool already_ready, void (*activate)(void *), void *context) {
  if (already_ready) {
    return false;
  }
  activate(context);
  return true;
}

#ifdef __cplusplus
  #include <chrono>

namespace platf::macos {
  // Execute the real startup transaction against injectable platform operations. A display
  // that disappears during the existing settle must be released, never passed to capture.
  template<class Create, class Wait, class Settle, class Destroy>
  bool prepare_virtual_display(Create create, Wait wait, Settle settle, Destroy destroy) {
    auto id = create();
    if (id == 0) {
      return false;
    }
    if (!wait(id, std::chrono::milliseconds(2000))) {
      destroy();
      return false;
    }
    settle();
    if (!wait(id, std::chrono::milliseconds(0))) {
      destroy();
      return false;
    }
    return true;
  }
}  // namespace platf::macos
#endif
