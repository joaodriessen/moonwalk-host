#pragma once

#include <cstdint>
#include <mutex>

namespace platf::macos {
  enum class capture_state { unknown, starting, complete, idle, blank, suspended, started, stopped, recovering, failed };

  inline const char *capture_state_name(capture_state state) {
    switch (state) {
      case capture_state::starting: return "starting";
      case capture_state::complete: return "complete";
      case capture_state::idle: return "idle";
      case capture_state::blank: return "blank";
      case capture_state::suspended: return "suspended";
      case capture_state::started: return "started";
      case capture_state::stopped: return "stopped";
      case capture_state::recovering: return "recovering";
      case capture_state::failed: return "failed";
      default: return "unknown";
    }
  }

  // Observed source facts, never an elapsed-time/pixel-change stall detector.
  // One capture owner is shared by the current single-desktop streaming path.
  // Generations prevent a superseded owner's teardown from changing its replacement.
  class capture_health {
  public:
    struct snapshot_t {
      std::uint64_t generation = 0;
      capture_state state = capture_state::unknown;
      std::uint64_t frames = 0;
      std::uint64_t cached_frames = 0;
      bool ready() const {
        return frames > 0 && (state == capture_state::complete || state == capture_state::idle);
      }
    };

    std::uint64_t begin() {
      std::lock_guard lock(mutex_);
      value_ = {value_.generation + 1, capture_state::starting, 0, 0};
      return value_.generation;
    }

    bool note(std::uint64_t generation, capture_state state, bool has_image) {
      std::lock_guard lock(mutex_);
      if (!generation || generation != value_.generation) return false;
      const bool complete = state == capture_state::complete && has_image;
      value_.state = state == capture_state::complete && !has_image ? capture_state::unknown : state;
      if (complete) ++value_.frames;
      return complete;
    }

    void cached(std::uint64_t generation) {
      std::lock_guard lock(mutex_);
      if (generation && generation == value_.generation) ++value_.cached_frames;
    }

    snapshot_t snapshot() const {
      std::lock_guard lock(mutex_);
      return value_;
    }

  private:
    mutable std::mutex mutex_;
    snapshot_t value_;
  };

  inline capture_health &screen_capture_health() {
    static capture_health health;
    return health;
  }
}
