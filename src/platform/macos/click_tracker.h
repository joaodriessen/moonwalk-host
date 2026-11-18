#pragma once

#include <chrono>
#include <limits>

namespace platf::macos {
  class click_tracker_t {
  public:
    using clock = std::chrono::steady_clock;

    int update(bool release, clock::time_point now, double x, double y, double interval) {
      if (release) {
        return count_ == 0 ? 1 : count_;
      }
      const auto elapsed = std::chrono::duration<double>(now - last_down_).count();
      const auto dx = x - x_;
      const auto dy = y - y_;
      // Cocoa exposes the user's time interval, but no public click-distance
      // preference. Use a small point-space slop, independent of Retina scale.
      const bool continues = count_ > 0 && elapsed >= 0 && elapsed <= interval && dx * dx + dy * dy <= 16.0;
      count_ = continues && count_ < std::numeric_limits<int>::max() ? count_ + 1 : 1;
      last_down_ = now;
      x_ = x;
      y_ = y;
      return count_;
    }

  private:
    clock::time_point last_down_ {};
    double x_ {}, y_ {};
    int count_ {};
  };
}  // namespace platf::macos
