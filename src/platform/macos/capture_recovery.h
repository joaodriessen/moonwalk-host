#pragma once

#include <chrono>

namespace platf::macos {
  // Shared budget survives replacement display/capture objects. A continuously
  // failing source cannot reset its budget simply by constructing another one.
  class capture_recovery_budget {
  public:
    bool request(std::chrono::steady_clock::time_point now) {
      if (attempts_ == 0 || now - window_ >= std::chrono::seconds(30)) {
        window_ = now;
        attempts_ = 0;
      }
      return ++attempts_ <= 3;
    }
  private:
    unsigned attempts_ = 0;
    std::chrono::steady_clock::time_point window_ {};
  };

}
