#pragma once

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string_view>

namespace video {
  struct frame_fec_status {
    std::uint32_t frame;
    unsigned data, parity, received_data, received_parity, missing;
    unsigned block, blocks;
  };

  inline std::optional<frame_fec_status> parse_frame_fec_status(std::string_view bytes) {
    if (bytes.size() != 21) return std::nullopt;
    auto u16 = [&](unsigned at) { return (unsigned(std::uint8_t(bytes[at])) << 8) | std::uint8_t(bytes[at + 1]); };
    auto u32 = [&](unsigned at) { return (std::uint32_t(u16(at)) << 16) | u16(at + 2); };
    frame_fec_status s {u32(0), u16(10), u16(12), u16(14), u16(16), u16(8), unsigned(std::uint8_t(bytes[19])), unsigned(std::uint8_t(bytes[20]))};
    if (!s.data || s.data > 1024 || s.parity > 1024 || s.received_data > s.data || s.received_parity > s.parity || !s.blocks || s.blocks > 4 || s.block >= s.blocks || s.missing > s.data + s.parity) return std::nullopt;
    return s;
  }

  // A client measuring the network itself sends this over the control stream. It
  // wants the encoder at target_kbps; pace_kbps > 0 asks for frames to be spread at
  // that rate; drain_frames asks for that many frames to be left out, once per
  // drain_sequence, so a queue on the link can empty.
  struct automatic_bitrate_report {
    int target_kbps, pace_kbps, queue_ms, loss_percent, drain_frames;
    std::uint32_t drain_sequence;
  };

  inline std::optional<automatic_bitrate_report> parse_automatic_bitrate_report(std::string_view bytes) {
    if (bytes.size() != 20 || std::uint8_t(bytes[0]) != 1) return std::nullopt;
    auto u32 = [&](unsigned at) {
      return std::uint32_t(std::uint8_t(bytes[at])) | (std::uint32_t(std::uint8_t(bytes[at + 1])) << 8) |
             (std::uint32_t(std::uint8_t(bytes[at + 2])) << 16) | (std::uint32_t(std::uint8_t(bytes[at + 3])) << 24);
    };
    const auto target = u32(4), pace = u32(8);
    if (!target || target > 1000000 || pace > 10000000) return std::nullopt;
    return automatic_bitrate_report {int(target), int(pace), int(u32(12) & 0xFFFF), int(std::uint8_t(bytes[2])),
                                     std::min<int>(std::uint8_t(bytes[1]), 8), u32(16)};
  }

  // Keeps what the encoder produces near the target by leaving frames out. Asked for less
  // than a picture can be coded at, an encoder settles on its own floor regardless: 11 Mbps
  // at 2880x1800 for the moving test scene, whatever the target. On a link slower than that,
  // fewer frames keep the delay low, where more would only queue and be lost.
  class automatic_frame_budget {
  public:
    using clock = std::chrono::steady_clock;
    bool allow(clock::time_point now, int target_kbps, int framerate) {
      const double bytes_per_second = target_kbps * 1000.0 / 8 * 1.25;
      if (started_) tokens_ += std::chrono::duration<double>(now - last_).count() * bytes_per_second;
      started_ = true;
      last_ = now;
      tokens_ = std::min(tokens_, std::max(bytes_per_second / 4, bytes_per_second * 2 / std::max(1, framerate)));
      // Never below ten frames a second, or the picture stops feeling alive at all.
      if (tokens_ > 0 || now - last_allowed_ >= std::chrono::milliseconds(100)) {
        last_allowed_ = now;
        return true;
      }
      return false;
    }
    void spent(std::uint64_t bytes) { tokens_ -= double(bytes); }
  private:
    bool started_ = false;
    double tokens_ = 0;
    clock::time_point last_ {}, last_allowed_ {};
  };

  // VideoToolbox follows a lower bitrate on a running session but stays down after that:
  // 11 Mbps at a 64 Mbps target, for a picture a fresh session codes at 29. So a session
  // that dipped, or was built during one, is worth replacing once the bitrate has doubled
  // and held for a few seconds, despite the brief hitch. Climbing with no dip needs none.
  inline bool rebuild_after_dip(int wanted_kbps, int lowest_kbps, int built_kbps, int negotiated_kbps,
                                std::chrono::steady_clock::duration session_age, std::chrono::steady_clock::duration since_decrease) {
    const bool lowered = lowest_kbps * 5 < built_kbps * 4 || built_kbps * 10 < negotiated_kbps * 9;
    return lowered && wanted_kbps >= lowest_kbps * 2 && session_age >= std::chrono::seconds(10) && since_decrease >= std::chrono::seconds(5);
  }

  // One control-thread owner; encoder reads only the atomic target. Updates are
  // bounded to one rebuild per 2s; recovery requires 10s of clean feedback. No
  // feedback means hold, never blindly increase. Ceiling is the adjusted request.
  class adaptive_bitrate_controller {
  public:
    explicit adaptive_bitrate_controller(int ceiling, int client_ceiling = 0): ceiling_(std::max(1, ceiling)), client_ceiling_(std::max(ceiling_, client_ceiling)), floor_(std::min(ceiling_, 1000)), target_(ceiling_) {}
    int target() const { return target_.load(std::memory_order_relaxed); }
    int ceiling() const { return ceiling_; }
    // Bitrate to spread frames at, or 0 to send them as fast as the host can. Pacing
    // to the encoder's own rate would stretch an average frame across a whole frame
    // interval, so a client that measures the link only asks for pacing when it helps.
    int pacing_kbps() const { return client_driven_.load(std::memory_order_relaxed) ? pace_.load(std::memory_order_relaxed) : target(); }
    bool client_driven() const { return client_driven_.load(std::memory_order_relaxed); }
    // True once per frame to be left out.
    bool take_drain_frame() {
      int remaining = drain_.load(std::memory_order_relaxed);
      while (remaining > 0) if (drain_.compare_exchange_weak(remaining, remaining - 1, std::memory_order_relaxed)) return true;
      return false;
    }
    // The control thread. Returns whether the change is worth logging.
    bool client_report(const automatic_bitrate_report &r) {
      client_driven_.store(true, std::memory_order_relaxed);
      const int next = std::clamp(r.target_kbps, floor_, client_ceiling_);
      target_.store(next, std::memory_order_relaxed);
      pace_.store(r.pace_kbps, std::memory_order_relaxed);
      if (r.drain_sequence != drain_sequence_) {
        drain_sequence_ = r.drain_sequence;
        drain_.store(r.drain_frames, std::memory_order_relaxed);
      }
      if (std::abs(next - logged_) * 8 < logged_) return false;
      logged_ = next;
      return true;
    }
    bool report(const frame_fec_status &s, std::chrono::steady_clock::time_point now) {
      if (client_driven()) return false;
      if (have_frame_ && std::int32_t(s.frame - last_frame_) < 0) return false;
      if (!have_frame_ || s.frame != last_frame_) block_mask_ = 0;
      if (block_mask_ & (1u << s.block)) return false;
      block_mask_ |= 1u << s.block;
      last_frame_ = s.frame;
      have_frame_ = true;
      // A gap is absence of evidence, not a clean network observation.
      if (have_report_ && now - last_report_ > std::chrono::seconds(1)) {
        have_clean_ = false;
        clean_reports_ = 0;
      }
      last_report_ = now;
      have_report_ = true;
      const bool loss = s.received_data < s.data || s.missing > 0;
      const auto received_total = std::uint64_t(s.received_data) + s.received_parity;
      const bool unrecovered = received_total < s.data;
      const bool severely_unrecovered = unrecovered && received_total * 4 < std::uint64_t(s.data) * 3;
      // Preserve recent worst loss through the rebuild gate; a later mild or
      // clean report must not hide it. Expire it after 1s without fresh loss.
      if (pending_percent_ < 100 && now - last_loss_ > std::chrono::seconds(1)) pending_percent_ = 100;
      if (loss) {
        pending_percent_ = std::min(pending_percent_, received_total * 4 < s.data ? 25 : severely_unrecovered ? 50 : unrecovered ? 75 : 90);
        last_loss_ = now;
        clean_since_ = now;
        have_clean_ = true;
        clean_reports_ = 0;
      } else if (!have_clean_) {
        clean_since_ = now;
        have_clean_ = true;
      }
      if (!loss) ++clean_reports_;
      if (have_adjustment_ && now - last_adjustment_ < std::chrono::seconds(2)) return false;
      int next = target();
      const bool applying_loss = pending_percent_ < 100;
      if (applying_loss) next = std::max(floor_, int(std::int64_t(next) * pending_percent_ / 100));
      else if (clean_reports_ >= 10 && now - clean_since_ >= std::chrono::seconds(10)) next = int(std::min(std::int64_t(ceiling_), std::int64_t(next) + std::max(100, std::min(ceiling_ / 20, next / 4))));
      pending_percent_ = 100;
      if (next == target()) return false;
      target_.store(next, std::memory_order_relaxed);
      last_adjustment_ = now;
      have_adjustment_ = true;
      if (!applying_loss) clean_since_ = now - std::chrono::seconds(5);
      return true;
    }
  private:
    int ceiling_, client_ceiling_, floor_;
    std::atomic<int> target_;
    std::atomic<int> pace_ {0};
    std::atomic<int> drain_ {0};
    std::atomic<bool> client_driven_ {false};
    std::uint32_t drain_sequence_ = 0;
    int logged_ = 0;
    std::uint32_t last_frame_ = 0;
    unsigned block_mask_ = 0, clean_reports_ = 0;
    int pending_percent_ = 100;
    std::chrono::steady_clock::time_point last_loss_ {};
    bool have_report_ = false;
    std::chrono::steady_clock::time_point last_report_ {};
    bool have_frame_ = false, have_clean_ = false, have_adjustment_ = false;
    std::chrono::steady_clock::time_point clean_since_ {}, last_adjustment_ {};
  };
}
