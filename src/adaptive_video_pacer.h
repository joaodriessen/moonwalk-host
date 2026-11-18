#pragma once

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>

namespace stream {
  // Broadcaster-owned, per-session debt. This bounds adaptive wire traffic;
  // it does not change encoder cadence or discard dependent encoded frames.
  class adaptive_video_pacer {
  public:
    using clock = std::chrono::steady_clock;

    static std::uint64_t wire_rate_bps(int target_kbps, int fec_percentage, std::size_t wire_bytes, std::size_t payload_bytes) {
      // The encoder target describes coded payload. Allow FEC and the actual
      // RTP/video/encryption/UDP/IP overhead rather than underfunding that payload.
      const auto coded_with_fec = std::uint64_t(std::max(1, target_kbps)) * 1000 * (100 + std::clamp(fec_percentage, 0, 255)) / 100;
      return std::max<std::uint64_t>(1, coded_with_fec * wire_bytes / std::max<std::size_t>(1, payload_bytes));
    }

    static std::size_t batch_size(int target_kbps, int fec_percentage, std::size_t wire_bytes, std::size_t payload_bytes, std::size_t platform_limit) {
      const auto rate = wire_rate_bps(target_kbps, fec_percentage, wire_bytes, payload_bytes);
      const auto packets_per_ms = rate / (std::max<std::size_t>(1, wire_bytes) * 8 * 1000);
      return std::max<std::size_t>(1, std::min<std::size_t>(platform_limit, packets_per_ms));
    }

    clock::time_point due(clock::time_point now) const {
      return std::max(next_, now);
    }

    void sent(clock::time_point now, std::size_t packets, int target_kbps, int fec_percentage, std::size_t wire_bytes, std::size_t payload_bytes) {
      const auto rate = wire_rate_bps(target_kbps, fec_percentage, wire_bytes, payload_bytes);
      const auto numerator = std::uint64_t(packets) * wire_bytes * 8 * 1000000000;
      const auto duration = std::chrono::nanoseconds((numerator + rate - 1) / rate);
      // A late wakeup earns no credit. Charge the last batch too, across FEC
      // blocks and frames, so neither boundary permits an extra burst.
      next_ = std::max(next_, now) + duration;
    }

  private:
    clock::time_point next_ {};
  };
}
