#pragma once

#include <memory>
#include <cstdint>
#include <string>

namespace platf {
  class mic_t;

  namespace macos {
    // Wrap a retained-by-owner SCAudioCapture in the normal C++ microphone
    // contract. The opaque bridge keeps ObjC frameworks out of C++ callers.
    std::unique_ptr<mic_t> make_system_audio_microphone(void *capture);
    // Wrap an already configured AVAudio input in the same capture contract.
    std::unique_ptr<mic_t> make_input_audio_microphone(void *capture);
    // Both streaming and the explicit local sound test use this factory. It never changes
    // saved/runtime configuration; resolved_source reports an actual fallback device.
    std::unique_ptr<mic_t> make_audio_microphone_for_source(const std::string &source, int channels,
      std::uint32_t sample_rate, std::uint32_t frame_size, std::string *resolved_source = nullptr,
      bool allow_permission_prompt = true);
  }  // namespace macos
}  // namespace platf
