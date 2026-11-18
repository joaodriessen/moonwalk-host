/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */

// standard includes
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <sstream>
#include <thread>
#include <unistd.h>

// platform includes
#include <IOKit/pwr_mgt/IOPMLib.h>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/black_frame_detector.h"
#include "src/platform/macos/capture_display_selection.h"
#include "src/platform/macos/capture_display_binding.h"
#include "src/platform/macos/virtual_display.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"
#import "src/platform/macos/sc_capture.h"
#include "src/platform/macos/virtual_display_readiness.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  /**
   * @brief Process a CMSampleBuffer frame into an img_t for the encoder pipeline.
   * Shared between AVFoundation and ScreenCaptureKit capture backends.
   */
  static bool process_frame(CMSampleBufferRef sampleBuffer, img_t *img) {
    // Check for valid pixel data before processing (SCK can deliver status frames without image content)
    CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixBuf) {
      return false;
    }

    auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
    auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

    auto av_img = (av_img_t *) img;

    auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer,
      av_img->pixel_buffer,
      img->data
    );

    av_img->sample_buffer = new_sample_buffer;
    av_img->pixel_buffer = new_pixel_buffer;
    img->data = new_pixel_buffer->data();

    img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
    img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
    img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
    // Deferred #12 (docs/design/2026-07-12-black-screen-permanent-fix.md §3 Mode 4 "adjacent cheap
    // fix"): a degenerate/phantom pixel buffer can report width == 0, and this divide previously had
    // no guard -- SIGFPE (integer division by zero) on that path. width == 0 now degrades to a
    // handled pixel_pitch of 0 instead of crashing.
    img->pixel_pitch = (img->width > 0) ? (img->row_pitch / img->width) : 0;

    // Capture-timestamp stamp. Wires up img->frame_timestamp on macOS, which was previously
    // left nullopt on every frame from both backends (SCK and AVFoundation share this function).
    // Activates three currently-dormant consumers the instant this starts returning real values:
    //   - video.cpp ~2285-2294: perf_cap_age_* running-mean/min/max counters (perf_trace-gated).
    //   - video.cpp ~2380 departure_got_real_frame: frame-departure phase-lock (mode 2) can now
    //     tell a real captured frame from a keepalive/backfill dup on macOS and re-phase its grid
    //     deadline off real arrivals instead of never re-phasing.
    //   - stream.cpp ~1369-1380: frame_processing_latency wire header sent to the client every
    //     packet (Moonlight's "host processing latency" stat -- purely informational/telemetry,
    //     clamped uint16 in 100us units; a stale/negative duration just clamps to 0, it cannot
    //     corrupt the field).
    //   - stream.cpp ~1559-1567: RTP timestamp (90kHz) is now derived from the real capture time
    //     instead of always falling back to ratecontrol_next_frame_start. Verified domain-safe:
    //     the fallback-assignment branch (`if (!packet->frame_timestamp) ...`) already handles
    //     nullopt, and monotonicity is preserved because CMSampleBuffer presentation timestamps
    //     are monotonically increasing per session and the now()-hostNow() offset used below is
    //     computed fresh on every call, so relative ordering between frames' converted
    //     steady_clock values tracks the ordering of their source pts values.
    img->frame_timestamp.reset();
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(pts) && pts.value != 0) {
      // Domain-safe conversion: do NOT assume steady_clock and SCK's mach-host-time-domain
      // presentation timestamps share an epoch. Both are mach-time-based on Apple platforms, but
      // steady_clock (mach_continuous_time) and CMClockGetHostTimeClock() (mach_absolute_time)
      // diverge across sleep/wake, so an assumed-equal-epoch conversion (pts interpreted directly
      // as a steady_clock duration) would silently drift stale after any display sleep. Instead,
      // compute the frame's age in the host clock's own domain -- CMClockGetHostTimeClock() now
      // minus pts -- and subtract that age from steady_clock::now(). This form only ever depends
      // on a duration measured within a single clock domain, so it is correct regardless of
      // whether the two clocks' epochs agree.
      CMTime host_now = CMClockGetTime(CMClockGetHostTimeClock());
      if (CMTIME_IS_VALID(host_now)) {
        double age_s = CMTimeGetSeconds(CMTimeSubtract(host_now, pts));
        if (std::isfinite(age_s)) {
          auto age = std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(age_s));
          // Clock-skew / sanity guard: only trust ages that look like a frame which was just
          // delivered. Negative age up to ~one frame interval is NORMAL: SCK stamps the frame's
          // PRESENTATION (next-vsync display) time, and delivery routinely lands several ms
          // ahead of it -- live measurement showed ~half of all frames arriving >5ms early, so
          // the lower bound is one 60Hz frame (-17ms) rather than jitter-only. Anything earlier
          // than that, or stale by more than 250ms, indicates diverged clock domains (or a bogus
          // pts) -- leave frame_timestamp unset rather than stamp garbage into the consumers.
          if (age >= -17ms && age <= 250ms) {
            img->frame_timestamp = std::chrono::steady_clock::now() - age;
          } else {
            static std::atomic<std::chrono::steady_clock::rep> last_skew_log_ns {0};
            auto now = std::chrono::steady_clock::now();
            auto prev_ns = last_skew_log_ns.load(std::memory_order_relaxed);
            std::chrono::steady_clock::time_point prev {std::chrono::steady_clock::duration {prev_ns}};
            if (now - prev > 5s) {
              last_skew_log_ns.store(now.time_since_epoch().count(), std::memory_order_relaxed);
              BOOST_LOG(debug) << "capture frame timestamp outside sane range (age="sv
                                << std::chrono::duration<double, std::milli>(age).count()
                                << "ms), leaving frame_timestamp unset"sv;
            }
          }
        }
      }
    }

    old_data_retainer = nullptr;
    return true;
  }

  // ── Display sleep-prevention + diagnostics (ported from upstream #5291) ──
  // Skylight is VD-first: capture always targets a fresh virtual display, so
  // physical-display wake was removed 2026-07-12 (see NOTE below) — waking a
  // powered-off panel steals the desktop from the VD instead of helping it.
  // create_display_sleep_assertion() below still holds the *target* display
  // (VD or physical) awake for the lifetime of the capture object, and the
  // diagnostics helpers log enough state to tell wake-related regressions
  // apart from other black-stream causes.
  namespace {
    const char *cg_error_name(CGError error) {
      switch (error) {
        case kCGErrorSuccess:
          return "success";
        case kCGErrorFailure:
          return "failure";
        case kCGErrorIllegalArgument:
          return "illegal argument";
        case kCGErrorInvalidConnection:
          return "invalid connection";
        case kCGErrorInvalidContext:
          return "invalid context";
        case kCGErrorCannotComplete:
          return "cannot complete";
        case kCGErrorNotImplemented:
          return "not implemented";
        case kCGErrorRangeCheck:
          return "range check";
        case kCGErrorTypeCheck:
          return "type check";
        case kCGErrorInvalidOperation:
          return "invalid operation";
        case kCGErrorNoneAvailable:
          return "none available";
        default:
          return "unknown";
      }
    }

    std::string format_rect(CGRect rect) {
      std::ostringstream formatted;
      formatted << '(' << rect.origin.x << ',' << rect.origin.y << ") "
                << rect.size.width << 'x' << rect.size.height;
      return formatted.str();
    }

    void log_display_diagnostic(CGDirectDisplayID display_id, const char *source) {
      NSString *display_name = [AVVideo getDisplayName:display_id];
      const char *display_name_utf8 = display_name ? display_name.UTF8String : "<unknown>";

      BOOST_LOG(info) << "Display diagnostic ["sv << source << "]: id: "sv << display_id
                      << ", name: "sv << display_name_utf8
                      << ", main: "sv << (display_id == CGMainDisplayID())
                      << ", active: "sv << CGDisplayIsActive(display_id)
                      << ", online: "sv << CGDisplayIsOnline(display_id)
                      << ", asleep: "sv << CGDisplayIsAsleep(display_id)
                      << ", built-in: "sv << CGDisplayIsBuiltin(display_id)
                      << ", bounds: "sv << format_rect(CGDisplayBounds(display_id));
    }

    void log_display_list_diagnostics(const char *list_name, CGError error, const CGDirectDisplayID *displays, uint32_t count) {
      BOOST_LOG(info) << list_name << ": status: "sv << cg_error_name(error)
                      << " ("sv << error << "), count: "sv << count;

      if (error != kCGErrorSuccess) {
        return;
      }

      for (uint32_t i = 0; i < count; ++i) {
        log_display_diagnostic(displays[i], list_name);
      }
    }

    void log_display_environment_diagnostics() {
      CGDirectDisplayID active_displays[kMaxDisplays];
      CGDirectDisplayID online_displays[kMaxDisplays];
      uint32_t active_display_count = 0;
      uint32_t online_display_count = 0;

      const auto active_error = CGGetActiveDisplayList(kMaxDisplays, active_displays, &active_display_count);
      const auto online_error = CGGetOnlineDisplayList(kMaxDisplays, online_displays, &online_display_count);

      BOOST_LOG(info) << "Main display diagnostic: id: "sv << CGMainDisplayID();
      log_display_list_diagnostics("CGGetActiveDisplayList", active_error, active_displays, active_display_count);
      log_display_list_diagnostics("CGGetOnlineDisplayList", online_error, online_displays, online_display_count);
    }

    // NOTE: wake_displays_for_detection() and its has_required_active_display()
    // helper were removed 2026-07-12 (superseding the partial gate in
    // 535d89f5). Skylight is VD-first: a fresh virtual display is always
    // created for streaming, and creating/activating that VD is itself a
    // display-configuration change that engages the compositor — physical
    // displays never need to be woken to make capture work. Waking a
    // powered-off-but-online physical panel via
    // IOPMAssertionDeclareUserActivity(kIOPMUserActiveRemote) re-activates it,
    // which steals the desktop from the VD (black stream) and is the prime
    // suspect for a WindowServer corruption that only cleared on reboot
    // (live-proven 2026-07-12: phantom "(AirPlay)" stand-in display). Do not
    // reintroduce a physical-display wake call here.

    // Holds the display awake for the duration of a capture session. Shared
    // by both the AVFoundation and ScreenCaptureKit backends below — each
    // owns one assertion for its own lifetime and releases it on teardown.
    IOPMAssertionID create_display_sleep_assertion() {
      IOPMAssertionID assertion = kIOPMNullAssertionID;
      const auto result = IOPMAssertionCreateWithName(
        kIOPMAssertPreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("Sunshine display capture"),
        &assertion
      );

      if (result == kIOReturnSuccess) {
        BOOST_LOG(info) << "Created display sleep prevention assertion, assertion id: "sv << assertion;
        return assertion;
      }

      BOOST_LOG(warning) << "Unable to create display sleep prevention assertion, IOReturn: "sv << result;
      return kIOPMNullAssertionID;
    }

    void release_display_sleep_assertion(IOPMAssertionID &assertion) {
      if (assertion == kIOPMNullAssertionID) {
        return;
      }

      const auto result = IOPMAssertionRelease(assertion);
      if (result != kIOReturnSuccess) {
        BOOST_LOG(warning) << "Unable to release display sleep assertion, IOReturn: "sv << result;
      }

      assertion = kIOPMNullAssertionID;
    }

    // ── Mode-4 dark-frame diagnostic ───────────────────────────────────
    // docs/design/2026-07-12-black-screen-permanent-fix.md §3 "Fix for Mode 4". See
    // black_frame_detector.h for the pure detection/decision state machine this glues to actual
    // CVPixelBuffer content.

    constexpr std::uint8_t kBlackFrameLuminanceThreshold = 2;  // out of 255; deliberately near-zero
    constexpr int kBlackFrameSampleGridSize = 5;  // 5x5 = 25 sparse sample points per sampled frame

    // P0 test hook (docs/design/2026-07-12-black-screen-permanent-fix.md Phase 0): when
    // SUNSHINE_TEST_FORCE_BLACK_FRAMES is set (to any non-empty value), every SAMPLED frame (per
    // the normal should_sample_next_frame cadence -- this does not bypass that gating, it only
    // forces the sampled VALUE) is reported as suspect-black without touching the real pixel
    // buffer, so the detector's real threshold/consecutive-count/diagnostic logic can be exercised
    // deterministically instead of waiting for a real black frame. OFF by default: with the env var
    // unset this is a single getenv() call and nothing else runs.
    bool force_black_frames_test_hook_enabled() {
      static bool logged_once = false;
      const char *env_val = getenv("SUNSHINE_TEST_FORCE_BLACK_FRAMES");
      const bool enabled = env_val && env_val[0] != '\0';
      if (enabled && !logged_once) {
        logged_once = true;
        BOOST_LOG(warning) << "TEST HOOK: SUNSHINE_TEST_FORCE_BLACK_FRAMES set -- forcing sampled frames to report as black"sv;
      }
      return enabled;
    }

    // Sparse, cheap luminance sample of a captured pixel buffer: kBlackFrameSampleGridSize^2 points
    // spread evenly across the frame, read-only locked for the duration. Planar biplanar formats
    // (NV12/P010, the hardware zero-copy encode path) sample plane 0 directly -- that IS the luma
    // (Y) channel, no color math needed. Packed formats (32BGRA, the software encode path) sample
    // max(B,G,R) per point as a conservative luminance proxy, ignoring alpha -- a truly black pixel
    // has all three color channels near zero regardless of this approximation.
    std::vector<std::uint8_t> sample_luminance_grid(CVPixelBufferRef pixBuf) {
      std::vector<std::uint8_t> samples;
      if (!pixBuf) {
        return samples;
      }

      if (CVPixelBufferLockBaseAddress(pixBuf, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return samples;
      }

      const size_t width = CVPixelBufferGetWidth(pixBuf);
      const size_t height = CVPixelBufferGetHeight(pixBuf);

      if (width > 0 && height > 0) {
        samples.reserve(kBlackFrameSampleGridSize * kBlackFrameSampleGridSize);

        if (CVPixelBufferIsPlanar(pixBuf)) {
          const OSType format = CVPixelBufferGetPixelFormatType(pixBuf);
          const bool is_16bit_luma = (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                                      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);

          void *plane_base = CVPixelBufferGetBaseAddressOfPlane(pixBuf, 0);
          const size_t plane_bytes_per_row = CVPixelBufferGetBytesPerRowOfPlane(pixBuf, 0);
          const size_t plane_width = CVPixelBufferGetWidthOfPlane(pixBuf, 0);
          const size_t plane_height = CVPixelBufferGetHeightOfPlane(pixBuf, 0);

          if (plane_base && plane_width > 0 && plane_height > 0) {
            for (int gy = 0; gy < kBlackFrameSampleGridSize; ++gy) {
              for (int gx = 0; gx < kBlackFrameSampleGridSize; ++gx) {
                size_t x = std::min(plane_width - 1, (plane_width * (size_t) (2 * gx + 1)) / (size_t) (2 * kBlackFrameSampleGridSize));
                size_t y = std::min(plane_height - 1, (plane_height * (size_t) (2 * gy + 1)) / (size_t) (2 * kBlackFrameSampleGridSize));
                const auto *row = static_cast<const std::uint8_t *>(plane_base) + y * plane_bytes_per_row;
                samples.push_back(is_16bit_luma ? row[x * 2 + 1] : row[x]);
              }
            }
          }
        } else {
          void *base = CVPixelBufferGetBaseAddress(pixBuf);
          const size_t bytes_per_row = CVPixelBufferGetBytesPerRow(pixBuf);
          const size_t bytes_per_pixel = bytes_per_row / width;  // width > 0 checked above

          if (base && bytes_per_pixel >= 3) {
            for (int gy = 0; gy < kBlackFrameSampleGridSize; ++gy) {
              for (int gx = 0; gx < kBlackFrameSampleGridSize; ++gx) {
                size_t x = std::min(width - 1, (width * (size_t) (2 * gx + 1)) / (size_t) (2 * kBlackFrameSampleGridSize));
                size_t y = std::min(height - 1, (height * (size_t) (2 * gy + 1)) / (size_t) (2 * kBlackFrameSampleGridSize));
                const auto *pixel = static_cast<const std::uint8_t *>(base) + y * bytes_per_row + x * bytes_per_pixel;
                samples.push_back(std::max({pixel[0], pixel[1], pixel[2]}));
              }
            }
          }
        }
      }

      CVPixelBufferUnlockBaseAddress(pixBuf, kCVPixelBufferLock_ReadOnly);
      return samples;
    }

    // Dark content is not proof of a broken capture. A black wallpaper, movie
    // fade or cached idle frame must never sleep/wake the local Mac. Actual
    // backend failures are recovered through SCCaptureOutcomeRecoverable.
    void note_suspect_dark_frame(CGDirectDisplayID display_id, int samples) {
      BOOST_LOG(info) << "Capture diagnostic: " << samples << " sampled dark frames on display " << display_id
                      << "; continuing capture (dark content alone does not trigger recovery)";
    }

    // Glue between the pure detector state machine and the real CVPixelBuffer: called once per
    // delivered frame from each capture backend's callback, right after process_frame() confirms
    // the sample buffer carried real pixel content. Cheap on frames the detector doesn't want
    // sampled -- should_sample_next_frame's steady-state gating means this is almost always just
    // that one boolean check and nothing else.
    void check_for_black_frame(CMSampleBufferRef sampleBuffer, CGDirectDisplayID display_id, platf::macos::BlackFrameDetector &detector) {
      if (!detector.should_sample_next_frame()) {
        return;
      }

      bool is_suspect_black;
      if (force_black_frames_test_hook_enabled()) {
        is_suspect_black = true;
      } else {
        CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
        auto sample = sample_luminance_grid(pixBuf);
        is_suspect_black = platf::macos::sample_is_suspect_black(sample, kBlackFrameLuminanceThreshold);
      }

      auto decision = detector.record_sample(is_suspect_black);
      if (decision.should_self_heal) {
        note_suspect_dark_frame(display_id, detector.consecutive_black());
      }
    }

    // P3 revised diagnostic instrumentation (docs/design/2026-07-12-p3-revised-off-display-uncapturable.md
    // §4.2): purely observational -- logs, never self-heals or otherwise changes behavior. The P3
    // Option A physical-capture skip was live-falsified and reverted (display_device.cpp always
    // creates the VD again now), so this log is no longer gated on a "physical capture" branch that
    // can never be taken. It fires unconditionally for the first N frames of every session's
    // capture (always VD-backed now), giving the owner's next reconnect an objective
    // mean/frac_nonblack readout to distinguish a real VD desktop from an empty extend, per
    // sunshine.log.
    constexpr int kCaptureStartupLumaLogFrames = 10;

    void log_capture_startup_luma(CMSampleBufferRef sampleBuffer, CGDirectDisplayID display_id, int &frames_logged) {
      if (frames_logged >= kCaptureStartupLumaLogFrames) {
        return;
      }

      CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
      auto sample = sample_luminance_grid(pixBuf);
      if (sample.empty()) {
        // No data extracted this frame (e.g. buffer lock failed) -- skip silently rather than
        // burn one of the N logged slots on a non-sample.
        return;
      }

      double sum = 0.0;
      std::size_t nonblack = 0;
      for (auto value : sample) {
        sum += value;
        if (value > kBlackFrameLuminanceThreshold) {
          ++nonblack;
        }
      }
      const double mean = sum / static_cast<double>(sample.size());
      const double frac_nonblack = static_cast<double>(nonblack) / static_cast<double>(sample.size());

      ++frames_logged;
      BOOST_LOG(info) << "capture startup luma: mean=" << mean << " frac_nonblack=" << frac_nonblack
                       << " frame=" << frames_logged << "/" << kCaptureStartupLumaLogFrames
                       << " display=" << display_id;
    }
  }  // namespace

  // ── AVFoundation capture backend (AVCaptureScreenInput) ──────────────

  struct av_display_t: public display_t {
    vd_geometry_t vd_geometry {};
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};
    IOPMAssertionID display_sleep_assertion {kIOPMNullAssertionID};
    // Mode-4 dark-frame diagnostic (docs/design/2026-07-12-black-screen-permanent-fix.md §3):
    // one detector instance per display_t instance, which the display() factory constructs fresh
    // on every connect/reconnect -- so this is naturally session-scoped, giving the "once per
    // session" self-heal budget for free.
    platf::macos::BlackFrameDetector black_frame_detector;
    // P3 revised (docs/design/2026-07-12-p3-revised-off-display-uncapturable.md §4.2): first-N-frame
    // startup-luma counter for this session's capture (always VD-backed; see create_virtual_display).
    int capture_luma_frames_logged {0};

    ~av_display_t() override {
      // Under ARC, av_capture is a __strong member of this C++ struct and is
      // released automatically on destruction.
      release_display_sleep_assertion(display_sleep_assertion);
    }

    capture_e capture(push_captured_image_cb_t push_captured_image_cb, pull_free_image_cb_t pull_free_image_cb, bool *cursor) override {
      const auto input_binding = macos::capture_display_binding().bind(display_id, env_width, env_height, &vd_geometry);
      auto input_binding_guard = util::fail_guard([input_binding] { macos::capture_display_binding().clear(input_binding); });
      // AVCaptureScreenInput has no live-reconfiguration API (unlike SCStream's
      // updateConfiguration:), and this backend is only reached when
      // ScreenCaptureKit is unavailable (pre-12.3, effectively dead on
      // supported macOS today) — so `cursor`/display_cursor is intentionally
      // not wired here; the AVFoundation fallback always shows the cursor.
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          return false;
        }
        if (process_frame(sampleBuffer, img_out.get())) {
          check_for_black_frame(sampleBuffer, display_id, black_frame_detector);
          log_capture_startup_luma(sampleBuffer, display_id, capture_luma_frames_logged);
        }
        if (!push_captured_image_cb(std::move(img_out), true)) {
          return false;
        }
        return true;
      }];

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown and not deadlock on teardown.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
        std::shared_ptr<img_t> probe_img;
        if (!pull_free_image_cb(probe_img)) {
          // Session is shutting down. Signal the semaphore so we exit the wait.
          // Don't call stopCapture here — the callback will detect shutdown on its
          // next invocation and do a clean teardown. Force-stopping AVFoundation
          // corrupts capture state for this display, causing black frames on reconnect.
          dispatch_semaphore_signal(signal);
          break;
        }
      }
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();
        // Non-owning back-reference: nv12_zero_device just stores this pointer
        // and hands it back to setResolution/setPixelFormat below while
        // av_capture (owned by this display_t) is still alive. __bridge (not
        // __bridge_retained) preserves that non-owning relationship under ARC.
        device->init((__bridge void *) av_capture, pix_fmt, setResolution, setPixelFormat);
        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame to avoid starting a capture session.
      // Starting and stopping AVFoundation capture for dummy_img can cause
      // timeouts on virtual displays and interfere with the main capture.
      int w = av_capture.frameWidth;
      int h = av_capture.frameHeight;

      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "AVFoundation dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * h);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      CVPixelBufferRelease(pixelBuffer);

      img->width = w;
      img->height = h;
      img->row_pitch = w * 4;
      img->pixel_pitch = 4;
      return 0;
    }

    static void setResolution(void *display, int width, int height) {
      [(__bridge AVVideo *) display setFrameWidth:width frameHeight:height];
    }

    static void setPixelFormat(void *display, OSType pixelFormat) {
      ((__bridge AVVideo *) display).pixelFormat = pixelFormat;
    }
  };

  // ── ScreenCaptureKit capture backend (macOS 12.3+) ──────────────────

  struct sc_display_t: public display_t {
    vd_geometry_t vd_geometry {};
    SCCapture *sc_capture {};
    CGDirectDisplayID display_id {};
    IOPMAssertionID display_sleep_assertion {kIOPMNullAssertionID};
    // Mode-4 dark-frame diagnostic (docs/design/2026-07-12-black-screen-permanent-fix.md §3):
    // one detector instance per display_t instance, which the display() factory constructs fresh
    // on every connect/reconnect -- so this is naturally session-scoped, giving the "once per
    // session" self-heal budget for free.
    platf::macos::BlackFrameDetector black_frame_detector;
    // P3 revised (docs/design/2026-07-12-p3-revised-off-display-uncapturable.md §4.2): first-N-frame
    // startup-luma counter for this session's capture (always VD-backed; see create_virtual_display).
    int capture_luma_frames_logged {0};
    bool capture_geometry_logged {false};

    ~sc_display_t() override {
      [sc_capture stopCapture];
      // Under ARC, sc_capture is a __strong member of this C++ struct and is
      // released automatically on destruction.
      release_display_sleep_assertion(display_sleep_assertion);
    }

    capture_e capture(push_captured_image_cb_t push_captured_image_cb, pull_free_image_cb_t pull_free_image_cb, bool *cursor) override {
      const auto input_binding = macos::capture_display_binding().bind(display_id, env_width, env_height, &vd_geometry);
      auto input_binding_guard = util::fail_guard([input_binding] { macos::capture_display_binding().clear(input_binding); });
      // Prime the stream's initial cursor-visibility state from the live
      // display_cursor flag (toggled by Moonlight's Ctrl+Alt+Shift+N) instead
      // of the previous hardcoded "always visible" default.
      BOOL initialShowsCursor = cursor ? (*cursor ? YES : NO) : YES;
      sc_capture.showsCursor = initialShowsCursor;
      __block BOOL cachedShowsCursor = initialShowsCursor;

      auto signal = [sc_capture captureVideo:^(CMSampleBufferRef sampleBuffer, BOOL cached) {
        // Per-frame, essentially-free comparison against the shared
        // display_cursor flag so a live toggle takes effect without a stream
        // restart — SCStream.updateConfiguration supports live showsCursor
        // changes (Apple-documented).
        if (cursor) {
          BOOL wantsCursor = *cursor ? YES : NO;
          if (wantsCursor != cachedShowsCursor) {
            cachedShowsCursor = wantsCursor;
            [sc_capture updateCursorVisibility:wantsCursor];
          }
        }

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          return false;
        }
        if (!process_frame(sampleBuffer, img_out.get())) {
          return true;  // skip this frame but continue capturing
        }
        img_out->cached_capture = cached;
        if (!capture_geometry_logged) {
          capture_geometry_logged = true;
          BOOST_LOG(info) << "Capture geometry: display=" << display_id
                          << " actual_buffer=" << img_out->width << 'x' << img_out->height
                          << " configured=" << sc_capture.frameWidth << 'x' << sc_capture.frameHeight
                          << " input_env=" << env_width << 'x' << env_height;
        }
        if (!cached) {
          check_for_black_frame(sampleBuffer, display_id, black_frame_detector);
          log_capture_startup_luma(sampleBuffer, display_id, capture_luma_frames_logged);
        }
        if (!push_captured_image_cb(std::move(img_out), true)) {
          return false;
        }
        return true;
      } audioCallback:nil];

      if (!signal) {
        BOOST_LOG(error) << "SCCapture failed to start video capture"sv;
        return capture_e::error;
      }

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown and not deadlock on teardown.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
        // Check if session is ending — pull_free_image_cb returns false when
        // the session is shutting down (capture_ctx_queue->running() == false).
        // This is needed because SCCapture may not deliver frames on an idle
        // display, so the video callback never gets a chance to detect shutdown.
        std::shared_ptr<img_t> probe_img;
        if (!pull_free_image_cb(probe_img)) {
          [sc_capture stopCapture];
          break;
        }
      }
      const auto outcome = [sc_capture captureResult];
      if (outcome == SCCaptureOutcomeRecoverable) return capture_e::reinit;
      if (outcome == SCCaptureOutcomeFatal) {
        BOOST_LOG(error) << "Screen capture stopped permanently; check Screen Recording permission or the selected capture source";
        return capture_e::error;
      }
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        sc_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();
        // Non-owning back-reference — see the identical comment in av_display_t
        // above. sc_capture (owned by this display_t) outlives the device.
        device->init((__bridge void *) sc_capture, pix_fmt, setResolution, setPixelFormat);
        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame instead of starting a separate capture.
      // Starting and stopping a capture just for dummy_img causes SCK to
      // not deliver frames to the subsequent main capture stream.
      int w = sc_capture.frameWidth;
      int h = sc_capture.frameHeight;

      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "SCCapture dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      // Fill with black
      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * h);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      // Wrap in a CMSampleBuffer for the av_img pipeline
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      CVPixelBufferRelease(pixelBuffer);

      img->width = w;
      img->height = h;
      img->row_pitch = w * 4;
      img->pixel_pitch = 4;
      return 0;
    }

    static void setResolution(void *display, int width, int height) {
      [(__bridge SCCapture *) display setFrameWidth:width frameHeight:height];
    }

    static void setPixelFormat(void *display, OSType pixelFormat) {
      ((__bridge SCCapture *) display).pixelFormat = pixelFormat;
    }
  };

  // ── Display factory ─────────────────────────────────────────────────

  static void seed_virtual_capture_geometry(SCCapture *capture, uint32_t selected, uint32_t virtual_id,
                                             int width, int height) {
    // Capture and VideoToolbox initialization run concurrently. Seed the known
    // VD backing size before publishing the display, so a missing CGDisplayMode
    // cannot make the initial SCStreamConfiguration depend on the later encoder
    // resolution callback. Physical capture retains its native geometry.
    if (virtual_id != 0 && selected == virtual_id && width > 0 && height > 0) {
      [capture setFrameWidth:width frameHeight:height];
    }
  }

#ifdef SUNSHINE_TESTS
  void test_capture_video_geometry(SCCapture *capture, uint32_t selected, uint32_t virtual_id,
                                   int width, int height) {
    seed_virtual_capture_geometry(capture, selected, virtual_id, width, height);
  }

  capture_e test_capture_video_bridge(SCCapture *capture, int *frames) {
    sc_display_t display;
    display.sc_capture = capture;
    display.display_id = 999999;
    display.env_width = display.width = 320;
    display.env_height = display.height = 180;
    return display.capture([frames](std::shared_ptr<img_t> &&, bool) { ++*frames; return true; },
      [](std::shared_ptr<img_t> &img) { img = std::make_shared<av_img_t>(); return true; }, nullptr);
  }
#endif

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    // Check if a virtual display is active — use it preferentially.
    auto vd_id = platf::virtual_display_get_id();

    BOOST_LOG(info) << "skipping physical display wake (VD-first: never wake physical panels)"sv;

    std::vector<uint32_t> active_ids;

    if (vd_id != 0) {
      auto bounds = CGDisplayBounds(vd_id);
      if (!skylight_virtual_display_ready(CGDisplayIsOnline(vd_id), CGDisplayIsActive(vd_id),
                                         CGDisplayIsInMirrorSet(vd_id), CGDisplayMirrorsDisplay(vd_id),
                                         bounds.size.width, bounds.size.height)) {
        log_display_diagnostic(vd_id, "virtual display unavailable before capture");
        BOOST_LOG(error) << "Virtual display became unavailable before capture. Check competing virtual-display management, then retry, or configure capture of an existing display."sv;
        return nullptr;
      }
      BOOST_LOG(info) << "Using virtual display (id: "sv << vd_id << ") for capture"sv;
    } else {
      log_display_environment_diagnostics();
      auto display_array = [AVVideo displayNames];
      BOOST_LOG(info) << "Detecting displays"sv;
      for (NSDictionary *item in display_array) {
        NSNumber *display_id = item[@"id"];
        NSString *name = item[@"displayName"];
        active_ids.push_back(display_id.unsignedIntValue);
        BOOST_LOG(info) << "Detected display: "sv << name.UTF8String << " (id: "sv << display_id.unsignedIntValue << ") connected: true"sv;
      }
    }
    const auto selected = macos::select_capture_display(vd_id, CGMainDisplayID(), display_name, active_ids);
    if (!selected) {
      BOOST_LOG(error) << "Requested capture display '"sv << display_name
                       << "' is invalid or no longer connected. Choose an available display or Automatic in Settings."sv;
      return nullptr;
    }
    const CGDirectDisplayID selected_display_id = *selected;
    vd_geometry_t verified_geometry {};
    if (vd_id != 0 && selected_display_id == vd_id &&
        (!virtual_display_get_geometry(vd_id, virtual_display_get_generation(), &verified_geometry) ||
         verified_geometry.pixel_width != config.width || verified_geometry.pixel_height != config.height)) {
      BOOST_LOG(error) << "Verified virtual display geometry unavailable; refusing capture";
      return nullptr;
    }
    log_display_diagnostic(selected_display_id, "selected for capture");
    BOOST_LOG(info) << "Configuring selected display ("sv << selected_display_id << ") to stream"sv;

    // ScreenCaptureKit capture backend — handles virtual display reconnection
    // reliably. AVFoundation's AVCaptureScreenInput stops delivering frames
    // when a virtual display is destroyed and recreated between sessions.
    if (@available(macOS 12.3, *)) {
      if ([SCCapture isAvailable]) {
        auto disp = std::make_shared<sc_display_t>();
        disp->vd_geometry = verified_geometry;
        disp->display_id = selected_display_id;
        disp->display_sleep_assertion = create_display_sleep_assertion();
        disp->sc_capture = [[SCCapture alloc] initWithDisplay:selected_display_id frameRate:config.framerate captureAudio:NO];

        if (!disp->sc_capture) {
          BOOST_LOG(error) << "SCCapture setup failed, trying AVFoundation..."sv;
        } else {
          seed_virtual_capture_geometry(disp->sc_capture, selected_display_id, vd_id, config.width, config.height);
          // Frame-departure gap-filler wiring (docs/design/pipeline-overhaul.md §3A;
          // docs/design/2026-07-13-cadence-phaselock.md §6). The capture-side v1 timer
          // (frameDeliveryTimer) is only ever created for frame_departure_mode == 1 -- the
          // default, shipped/live behavior, byte-identical to today. Mode 0 (off) and mode 2
          // (v2-A encode-side phase-lock, driven separately in video.cpp's encode_run) both
          // leave it NO so v1 and v2 can never both backfill at once. ::config:: (leading ::)
          // disambiguates the global config namespace from this function's own `config`
          // parameter (a video::config_t&).
          disp->sc_capture.steadyFrameDelivery = (::config::video.frame_departure_mode == 1) ? YES : NO;
          disp->width = disp->sc_capture.frameWidth;
          disp->height = disp->sc_capture.frameHeight;
          disp->env_width = disp->width;
          disp->env_height = disp->height;
          return disp;
        }
      }
    }

    // Fallback: AVFoundation capture backend
    auto disp = std::make_shared<av_display_t>();
    disp->vd_geometry = verified_geometry;
    disp->display_id = selected_display_id;
    disp->display_sleep_assertion = create_display_sleep_assertion();
    disp->av_capture = [[AVVideo alloc] initWithDisplay:selected_display_id frameRate:config.framerate];

    if (!disp->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    if (vd_geometry_valid(&verified_geometry)) [disp->av_capture setFrameWidth:verified_geometry.pixel_width frameHeight:verified_geometry.pixel_height];
    disp->width = disp->av_capture.frameWidth;
    disp->height = disp->av_capture.frameHeight;
    disp->env_width = disp->width;
    disp->env_height = disp->height;

    return disp;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> display_names;

    auto display_array = [AVVideo displayNames];

    display_names.reserve([display_array count]);
    [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
      NSString *name = obj[@"name"];
      display_names.emplace_back(name.UTF8String);
    }];

    return display_names;
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
