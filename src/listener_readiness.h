#pragma once
#include <array>
#include <atomic>

namespace net {
  enum class listener_kind : unsigned { http, https, rtsp };
  inline std::array<std::atomic_bool, 3> bound_stream_listeners {};
  inline void set_listener_ready(listener_kind kind, bool ready) {
    bound_stream_listeners[static_cast<unsigned>(kind)].store(ready);
  }
  inline bool listener_ready(listener_kind kind) {
    return bound_stream_listeners[static_cast<unsigned>(kind)].load();
  }
}
