#pragma once

#include <functional>
#include <mutex>

namespace rtsp_stream {
  // Owns resources prepared before a stream exists. Expiry is explicit, so a
  // stalled TCP socket retaining launch_session_t cannot retain its display.
  class pending_launch_t {
  public:
    ~pending_launch_t() {
      expire();
    }

    void arm(std::function<void()> cleanup) {
      std::lock_guard lock(mutex_);
      cleanup_ = std::move(cleanup);
    }

    void expire() {
      std::function<void()> cleanup;
      {
        std::lock_guard lock(mutex_);
        if (state_ != state::pending) {
          return;
        }
        state_ = state::expired;
        cleanup = std::move(cleanup_);
      }
      if (cleanup) {
        cleanup();
      }
    }

    // Serialize acceptance with expiration. Ownership transfers only after the
    // actual stream start succeeds. A rejected/failed start keeps cleanup armed.
    bool accept(const std::function<bool()> &start) {
      std::lock_guard lock(mutex_);
      if (state_ != state::pending || !start()) {
        return false;
      }
      state_ = state::accepted;
      cleanup_ = {};
      return true;
    }

  private:
    enum class state {
      pending,
      accepted,
      expired
    };
    std::mutex mutex_;
    state state_ {state::pending};
    std::function<void()> cleanup_;
  };
}  // namespace rtsp_stream
