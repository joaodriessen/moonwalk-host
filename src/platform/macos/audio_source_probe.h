#pragma once
#include "src/platform/common.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <functional>

namespace platf::macos {
  struct audio_probe_result {
    std::size_t samples = 0;
    float peak = 0;
    bool cancelled = false;
    bool failed = false;
  };

  // Streaming mic_t::sample has a bounded no-data timeout. The owner destroys the mic
  // after this returns; no audio is retained and only aggregate level/sample counts escape.
  inline audio_probe_result probe_audio_source(mic_t &microphone, const std::atomic_bool &cancel,
      std::chrono::milliseconds duration = std::chrono::seconds(2), const std::function<bool()> &should_stop = {}) {
    audio_probe_result result;
    std::vector<float> samples(960); // 10 ms stereo at 48 kHz
    const auto deadline = std::chrono::steady_clock::now() + duration;
    while (!cancel && std::chrono::steady_clock::now() < deadline) {
      if (should_stop && should_stop()) { result.cancelled = true; break; }
      const auto state = microphone.sample(samples);
      if (state == capture_e::timeout) { continue; }
      if (state != capture_e::ok) { result.failed = true; break; }
      result.samples += samples.size();
      for (float sample : samples) {
        if (std::isfinite(sample)) { result.peak = std::max(result.peak, std::abs(sample)); }
      }
    }
    result.cancelled = result.cancelled || cancel.load();
    return result;
  }
}
