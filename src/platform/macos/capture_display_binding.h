#pragma once

#include <cstdint>
#include <mutex>
#include <algorithm>
#include <utility>
#include "vd_geometry.h"

namespace platf::macos {
  // The capture thread publishes the display it actually opened. Probes never
  // publish a target, and a retiring capture cannot clear a newer binding.
  class capture_display_binding_t {
  public:
    struct snapshot_t {
      uint32_t display {};
      int pixel_width {}, pixel_height {};
      uint64_t generation {};
      vd_geometry_t geometry {};

      bool has_geometry() const {
        return pixel_width > 0 && pixel_height > 0 && geometry.generation && geometry.display == display &&
            geometry.pixel_width == pixel_width && geometry.pixel_height == pixel_height && vd_geometry_valid(&geometry);
      }
      std::pair<double, double> logical_point(double x, double y) const {
        return {geometry.x + std::clamp(x * geometry.logical_width / pixel_width, 0.0, double(geometry.logical_width - 1)),
                geometry.y + std::clamp(y * geometry.logical_height / pixel_height, 0.0, double(geometry.logical_height - 1))};
      }
    };

    uint64_t bind(uint32_t display, int pixel_width, int pixel_height, const vd_geometry_t *geometry = nullptr) {
      std::lock_guard lock(mutex_);
      current_ = {display, pixel_width, pixel_height, next_generation_++};
      if (geometry) current_.geometry = *geometry;
      return current_.generation;
    }

    void clear(uint64_t generation) {
      std::lock_guard lock(mutex_);
      if (current_.generation == generation) {
        current_ = {};
      }
    }

    snapshot_t snapshot() const {
      std::lock_guard lock(mutex_);
      return current_;
    }

  private:
    mutable std::mutex mutex_;
    snapshot_t current_;
    uint64_t next_generation_ {1};
  };

  capture_display_binding_t &capture_display_binding();
  uint32_t input_display_target();
}  // namespace platf::macos
