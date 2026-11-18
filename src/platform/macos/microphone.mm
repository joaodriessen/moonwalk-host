/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for microphone/audio capture on macOS.
 * @details Supports:
 *   - System audio capture via ScreenCaptureKit (macOS 12.3+; this is the default path, since
 *     this project's deployment target is 14.0 no extra software is needed for system audio)
 *   - Physical microphone capture via AVFoundation
 *   - Optional manual routing to a specific AVFoundation input device (e.g. a virtual audio
 *     device such as BlackHole), only if the user explicitly configures one as `audio_sink`
 */
// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_audio.h"
#include "src/platform/macos/sc_audio.h"
#include "src/platform/macos/audio_capture_policy.h"
#include "src/platform/macos/audio_capture_bridge.h"

namespace platf {
  using namespace std::literals;

  /**
   * @brief Microphone capture using AVFoundation (for physical mics and BlackHole)
   */
  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};

    // Under ARC, av_audio_capture is a __strong member of this C++ struct
    // (compiled in this ARC translation unit) — it is released automatically
    // when the struct is destroyed. No explicit ~av_mic_t() is needed.

    capture_e sample(std::vector<float> &sample_in) override {
      // setupMicrophone's startRunning is synchronous. A session that has
      // stopped must enter the caller's reopen path, even with old PCM queued.
      if (!av_audio_capture.audioCaptureSession.isRunning) {
        return capture_e::reinit;
      }
      auto sample_size = sample_in.size();

      uint32_t length = 0;
      void *byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);

      int wait_count = 0;
      while (length < sample_size * sizeof(float)) {
        [av_audio_capture.samplesArrivedSignal lock];
        [av_audio_capture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [av_audio_capture.samplesArrivedSignal unlock];
        if (!av_audio_capture.audioCaptureSession.isRunning) {
          return capture_e::reinit;
        }
        byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);
        // After 500ms of no data, return timeout so the caller can check shutdown_event
        if (++wait_count > 5 && length < sample_size * sizeof(float)) {
          return capture_e::timeout;
        }
      }

      const float *sampleBuffer = (float *) byteSampleBuffer;
      std::vector<float> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

      std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

      TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, (uint32_t) sample_size * sizeof(float));

      return capture_e::ok;
    }
  };

  std::unique_ptr<mic_t> macos::make_input_audio_microphone(void *capture) {
    auto mic = std::make_unique<av_mic_t>();
    mic->av_audio_capture = (__bridge AVAudio *)capture;
    return mic;
  }

  /**
   * @brief System audio capture using ScreenCaptureKit (macOS 12.3+)
   */
  struct sc_mic_t: public mic_t {
    SCAudioCapture *sc_audio_capture API_AVAILABLE(macos(12.3)) {};

    // Stop while this owner still holds the capture. ARC releases the strong
    // member afterwards; active framework outputs must not keep it running.
    ~sc_mic_t() override {
      [sc_audio_capture stopCapture];
    }

    capture_e sample(std::vector<float> &sample_in) override {
      if (@available(macOS 12.3, *)) {
        if (!sc_audio_capture.isCapturing) {
          return capture_e::reinit;
        }
        auto sample_size = sample_in.size();

        uint32_t length = 0;
        TPCircularBuffer *buffer = [sc_audio_capture getAudioBuffer];
        void *byteSampleBuffer = TPCircularBufferTail(buffer, &length);

        int wait_count = 0;
        while (length < sample_size * sizeof(float)) {
          if (!sc_audio_capture.isCapturing) {
            return capture_e::reinit;
          }
          [sc_audio_capture.samplesArrivedSignal lock];
          [sc_audio_capture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
          [sc_audio_capture.samplesArrivedSignal unlock];
          byteSampleBuffer = TPCircularBufferTail(buffer, &length);
          // After 500ms of no data, return timeout so the caller can check shutdown_event
          if (++wait_count > 5 && length < sample_size * sizeof(float)) {
            return capture_e::timeout;
          }
        }

        const float *sampleBuffer = (float *) byteSampleBuffer;
        std::vector<float> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

        std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

        TPCircularBufferConsume(buffer, (uint32_t) sample_size * sizeof(float));

        return capture_e::ok;
      }
      return capture_e::error;
    }
  };

  std::unique_ptr<mic_t> macos::make_system_audio_microphone(void *capture) {
    auto mic = std::make_unique<sc_mic_t>();
    mic->sc_audio_capture = (__bridge SCAudioCapture *)capture;
    return mic;
  }

    std::unique_ptr<mic_t> macos::make_audio_microphone_for_source(const std::string &source, int channels,
      std::uint32_t sample_rate, std::uint32_t frame_size, std::string *resolved_source, bool allow_permission_prompt) {
      AVCaptureDevice *audio_capture_device = nil;
      const char *audio_sink = source.c_str();

      // Check if user wants system audio or has no sink specified
      bool want_system_audio = macos::uses_native_system_audio(source);

      if (!macos::audio_channels_supported(source, channels)) {
        BOOST_LOG(error) << "Native Mac system audio requires stereo negotiation"sv;
        return nullptr;
      }

      // Try ScreenCaptureKit for system audio (macOS 12.3+)
      if (want_system_audio) {
        if (@available(macOS 12.3, *)) {
          if ([SCAudioCapture isAvailable]) {
            BOOST_LOG(info) << "Attempting native system audio capture via ScreenCaptureKit..."sv;

            SCAudioCapture *capture = [[SCAudioCapture alloc] init];
            auto sc_mic = macos::make_system_audio_microphone((__bridge void *)capture);

            if ([capture startCaptureWithSampleRate:sample_rate channels:channels] == 0) {
              if (resolved_source) { *resolved_source = "This Mac’s system audio"; }
              BOOST_LOG(info) << "System audio capture enabled via ScreenCaptureKit!"sv;
              return sc_mic;
            } else {
              BOOST_LOG(warning) << "ScreenCaptureKit audio capture failed, falling back to other methods"sv;
              // The microphone owner stops partial capture before ARC releases
              // it, including error paths where isCapturing is already NO.
            }
          }
        }
      }

      // Fall back to AVFoundation-based capture (microphones, BlackHole, etc.)
      // Try to find the specified audio source
      audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]];

      // Optional advanced fallback: if ScreenCaptureKit wasn't used/available and no specific
      // sink was found, opportunistically check for a manually-installed BlackHole device.
      // This is a convenience for users who set up their own routing, not how system audio
      // capture normally works (ScreenCaptureKit above already handles that).
      if (audio_capture_device == nullptr && (source.empty() || want_system_audio)) {
        NSArray<NSString *> *availableInputs = [AVAudio microphoneNames];

        for (NSString *name in availableInputs) {
          if ([name containsString:@"BlackHole"]) {
            BOOST_LOG(info) << "Auto-detected BlackHole audio device: "sv << [name UTF8String];
            audio_capture_device = [AVAudio findMicrophone:name];
            break;
          }
        }
      }

      if (audio_capture_device == nullptr) {
        BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
        BOOST_LOG(error) << "Available inputs:"sv;

        for (NSString *name in [AVAudio microphoneNames]) {
          BOOST_LOG(error) << "\t"sv << [name UTF8String];
        }

        // Note: this project's deployment target is macOS 14.0, so ScreenCaptureKit
        // (macOS 12.3+) is always available here — no pre-12.3 fallback guidance needed.
        BOOST_LOG(info) << "Tip: For system audio capture, ensure Screen Recording permission is granted in System Settings."sv;
        BOOST_LOG(info) << "     Set audio_sink = system in your config to use ScreenCaptureKit."sv;

        return nullptr;
      }

      if (resolved_source) { *resolved_source = [audio_capture_device.localizedName UTF8String]; }
      if (!allow_permission_prompt && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        return nullptr;
      }
      AVAudio *capture = [[AVAudio alloc] init];

      if ([capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
        BOOST_LOG(error) << "Failed to setup microphone."sv;
        return nullptr;
      }
      if (resolved_source) { *resolved_source = [audio_capture_device.localizedName UTF8String]; }
      return macos::make_input_audio_microphone((__bridge void *)capture);
    }

  struct macos_audio_control_t: public audio_control_t {
  public:
    int set_sink(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
      return 0;
    }

    std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size, bool continuous_audio) override {
      return macos::make_audio_microphone_for_source(config::audio.sink, channels, sample_rate, frame_size);
    }

    bool is_sink_available(const std::string &sink) override {
      // Check for ScreenCaptureKit availability
      if (sink.empty() || sink == "system" || sink == "desktop" || sink == "screencapturekit") {
        if (@available(macOS 12.3, *)) {
          return [SCAudioCapture isAvailable];
        }
      }

      // Check for physical input devices
      return [AVAudio findMicrophone:[NSString stringWithUTF8String:sink.c_str()]] != nil;
    }

    std::optional<sink_t> sink_info() override {
      sink_t sink;

      // Report available audio sources
      if (@available(macOS 12.3, *)) {
        if ([SCAudioCapture isAvailable]) {
          sink.host = "System Audio (ScreenCaptureKit)";
        }
      }

      return sink;
    }
  };

  std::unique_ptr<audio_control_t> audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf
