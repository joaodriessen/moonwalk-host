#pragma once

#include <cctype>
#include <string>
#include <string_view>

namespace platf::macos {
  inline bool uses_native_system_audio(std::string_view sink) {
    std::string name {sink};
    for (auto &ch : name) {
      ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return name.empty() || name == "system" || name == "desktop" || name == "screencapturekit";
  }

  // SCK falls back to stereo for unsupported channel counts. Keep this contract
  // consistent across serverinfo, DESCRIBE, ANNOUNCE and the capture source.
  inline int audio_channel_limit(std::string_view sink) {
    return uses_native_system_audio(sink) ? 2 : 8;
  }

  inline bool audio_channels_supported(std::string_view sink, int channels) {
    return (channels == 2 || channels == 6 || channels == 8) && channels <= audio_channel_limit(sink);
  }
}  // namespace platf::macos
