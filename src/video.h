/**
 * @file src/video.h
 * @brief Declarations for video.
 */
#pragma once

// standard includes
#include <cstdint>
#include <memory>
#include <string>

// local includes
#include "input.h"
#include "adaptive_bitrate.h"
#include "platform/common.h"
#include "thread_safe.h"
#include "video_colorspace.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
}

struct AVPacket;

namespace video {

  /* Encoding configuration requested by remote client */
  struct config_t {
    int width;  // Video width in pixels
    int height;  // Video height in pixels
    int framerate;  // Requested framerate, used in individual frame bitrate budget calculation
    int framerateX100;  // Optional field for streaming at NTSC or similar rates e.g. 59.94 = 5994
    int bitrate;  // Video bitrate in kilobits (1000 bits) for requested framerate
    int slicesPerFrame;  // Number of slices per frame
    int numRefFrames;  // Max number of reference frames

    /* Requested color range and SDR encoding colorspace, HDR encoding colorspace is always BT.2020+ST2084
       Color range (encoderCscMode & 0x1) : 0 - limited, 1 - full
       SDR encoding colorspace (encoderCscMode >> 1) : 0 - BT.601, 1 - BT.709, 2 - BT.2020 */
    int encoderCscMode;

    int videoFormat;  // 0 - H.264, 1 - HEVC, 2 - AV1

    /* Encoding color depth (bit depth): 0 - 8-bit, 1 - 10-bit
       HDR encoding activates when color depth is higher than 8-bit and the display which is being captured is operating in HDR mode */
    int dynamicRange;

    int chromaSamplingType;  // 0 - 4:2:0, 1 - 4:4:4

    int enableIntraRefresh;  // 0 - disabled, 1 - enabled
    std::shared_ptr<adaptive_bitrate_controller> adaptive_bitrate;
    std::weak_ptr<void> channel_owner;
  };

  platf::mem_type_e map_base_dev_type(AVHWDeviceType type);
  platf::pix_fmt_e map_pix_fmt(AVPixelFormat fmt);

  void free_ctx(AVCodecContext *ctx);
  void free_frame(AVFrame *frame);
  void free_buffer(AVBufferRef *ref);

  using avcodec_ctx_t = util::safe_ptr<AVCodecContext, free_ctx>;
  using avcodec_frame_t = util::safe_ptr<AVFrame, free_frame>;
  using avcodec_buffer_t = util::safe_ptr<AVBufferRef, free_buffer>;
  using sws_t = util::safe_ptr<SwsContext, sws_freeContext>;
  using img_event_t = std::shared_ptr<safe::event_t<std::shared_ptr<platf::img_t>>>;

  struct encoder_platform_formats_t {
    virtual ~encoder_platform_formats_t() = default;
    platf::mem_type_e dev_type;
    platf::pix_fmt_e pix_fmt_8bit, pix_fmt_10bit;
    platf::pix_fmt_e pix_fmt_yuv444_8bit, pix_fmt_yuv444_10bit;
  };

  struct encoder_platform_formats_avcodec: encoder_platform_formats_t {
    using init_buffer_function_t = std::function<util::Either<avcodec_buffer_t, int>(platf::avcodec_encode_device_t *)>;

    encoder_platform_formats_avcodec(
      const AVHWDeviceType &avcodec_base_dev_type,
      const AVHWDeviceType &avcodec_derived_dev_type,
      const AVPixelFormat &avcodec_dev_pix_fmt,
      const AVPixelFormat &avcodec_pix_fmt_8bit,
      const AVPixelFormat &avcodec_pix_fmt_10bit,
      const AVPixelFormat &avcodec_pix_fmt_yuv444_8bit,
      const AVPixelFormat &avcodec_pix_fmt_yuv444_10bit,
      const init_buffer_function_t &init_avcodec_hardware_input_buffer_function
    ):
        avcodec_base_dev_type {avcodec_base_dev_type},
        avcodec_derived_dev_type {avcodec_derived_dev_type},
        avcodec_dev_pix_fmt {avcodec_dev_pix_fmt},
        avcodec_pix_fmt_8bit {avcodec_pix_fmt_8bit},
        avcodec_pix_fmt_10bit {avcodec_pix_fmt_10bit},
        avcodec_pix_fmt_yuv444_8bit {avcodec_pix_fmt_yuv444_8bit},
        avcodec_pix_fmt_yuv444_10bit {avcodec_pix_fmt_yuv444_10bit},
        init_avcodec_hardware_input_buffer {init_avcodec_hardware_input_buffer_function} {
      dev_type = map_base_dev_type(avcodec_base_dev_type);
      pix_fmt_8bit = map_pix_fmt(avcodec_pix_fmt_8bit);
      pix_fmt_10bit = map_pix_fmt(avcodec_pix_fmt_10bit);
      pix_fmt_yuv444_8bit = map_pix_fmt(avcodec_pix_fmt_yuv444_8bit);
      pix_fmt_yuv444_10bit = map_pix_fmt(avcodec_pix_fmt_yuv444_10bit);
    }

    AVHWDeviceType avcodec_base_dev_type, avcodec_derived_dev_type;
    AVPixelFormat avcodec_dev_pix_fmt;
    AVPixelFormat avcodec_pix_fmt_8bit, avcodec_pix_fmt_10bit;
    AVPixelFormat avcodec_pix_fmt_yuv444_8bit, avcodec_pix_fmt_yuv444_10bit;

    init_buffer_function_t init_avcodec_hardware_input_buffer;
  };

  struct encoder_platform_formats_nvenc: encoder_platform_formats_t {
    encoder_platform_formats_nvenc(
      const platf::mem_type_e &dev_type,
      const platf::pix_fmt_e &pix_fmt_8bit,
      const platf::pix_fmt_e &pix_fmt_10bit,
      const platf::pix_fmt_e &pix_fmt_yuv444_8bit,
      const platf::pix_fmt_e &pix_fmt_yuv444_10bit
    ) {
      encoder_platform_formats_t::dev_type = dev_type;
      encoder_platform_formats_t::pix_fmt_8bit = pix_fmt_8bit;
      encoder_platform_formats_t::pix_fmt_10bit = pix_fmt_10bit;
      encoder_platform_formats_t::pix_fmt_yuv444_8bit = pix_fmt_yuv444_8bit;
      encoder_platform_formats_t::pix_fmt_yuv444_10bit = pix_fmt_yuv444_10bit;
    }
  };

  struct encoder_t {
    std::string_view name;

    enum flag_e {
      PASSED,  ///< Indicates the encoder is supported.
      REF_FRAMES_RESTRICT,  ///< Set maximum reference frames.
      DYNAMIC_RANGE,  ///< HDR support.
      YUV444,  ///< YUV 4:4:4 support.
      VUI_PARAMETERS,  ///< AMD encoder with VAAPI doesn't add VUI parameters to SPS.
      MAX_FLAGS  ///< Maximum number of flags.
    };

    static std::string_view from_flag(flag_e flag) {
#define _CONVERT(x) \
  case flag_e::x: \
    return std::string_view(#x)
      switch (flag) {
        _CONVERT(PASSED);
        _CONVERT(REF_FRAMES_RESTRICT);
        _CONVERT(DYNAMIC_RANGE);
        _CONVERT(YUV444);
        _CONVERT(VUI_PARAMETERS);
        _CONVERT(MAX_FLAGS);
      }
#undef _CONVERT

      return {"unknown"};
    }

    struct option_t {
      KITTY_DEFAULT_CONSTR_MOVE(option_t)
      option_t(const option_t &) = default;

      std::string name;
      std::variant<int, int *, std::optional<int> *, std::function<int()>, std::string, std::string *, std::function<const std::string(const config_t &)>> value;

      option_t(std::string &&name, decltype(value) &&value):
          name {std::move(name)},
          value {std::move(value)} {
      }
    };

    const std::unique_ptr<const encoder_platform_formats_t> platform_formats;

    struct codec_t {
      std::vector<option_t> common_options;
      std::vector<option_t> sdr_options;
      std::vector<option_t> hdr_options;
      std::vector<option_t> sdr444_options;
      std::vector<option_t> hdr444_options;
      std::vector<option_t> fallback_options;

      std::string name;
      std::bitset<MAX_FLAGS> capabilities;

      bool operator[](flag_e flag) const {
        return capabilities[(std::size_t) flag];
      }

      std::bitset<MAX_FLAGS>::reference operator[](flag_e flag) {
        return capabilities[(std::size_t) flag];
      }
    } av1, hevc, h264;

    const codec_t &codec_from_config(const config_t &config) const {
      switch (config.videoFormat) {
        default:
          BOOST_LOG(error) << "Unknown video format " << config.videoFormat << ", falling back to H.264";
          // fallthrough
        case 0:
          return h264;
        case 1:
          return hevc;
        case 2:
          return av1;
      }
    }

    uint32_t flags;
  };

  struct encode_session_t {
    // Changes the running encoder's bitrate if it can. False means it needs rebuilding.
    virtual bool set_bitrate(int kbps) { return false; }

    virtual ~encode_session_t() = default;

    std::weak_ptr<void> channel_owner;

    virtual int convert(platf::img_t &img) = 0;

    virtual void request_idr_frame() = 0;

    virtual void request_normal_frame() = 0;

    virtual void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) = 0;
  };

  // encoders
  extern encoder_t software;

#if !defined(__APPLE__)
  extern encoder_t nvenc;  // available for windows and linux
#endif

#ifdef _WIN32
  extern encoder_t amdvce;
  extern encoder_t quicksync;
  extern encoder_t mediafoundation;
#endif

#if defined(__linux__) || defined(linux) || defined(__linux) || defined(__FreeBSD__)
  extern encoder_t vaapi;
#endif

#ifdef __APPLE__
  extern encoder_t videotoolbox;
#endif

  struct packet_raw_t {
    virtual ~packet_raw_t() = default;

    virtual bool is_idr() = 0;

    virtual int64_t frame_index() = 0;

    virtual uint8_t *data() = 0;

    virtual size_t data_size() = 0;

    struct replace_t {
      std::string old;
      std::string _new;

      KITTY_DEFAULT_CONSTR_MOVE(replace_t)

      replace_t(std::string_view old, std::string_view _new):
          old {old},
          _new {_new} {
      }
    };

    // Queued packets may outlive the encoder and its SPS/VPS buffers.
    std::shared_ptr<const std::vector<replace_t>> replacements;
    void *channel_data = nullptr;
    // The transport may still be sending after this session leaves its RTSP slot.
    std::shared_ptr<void> channel_owner;
    bool after_ref_frame_invalidation = false;
    std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
  };

  struct packet_raw_avcodec: packet_raw_t {
    packet_raw_avcodec() {
      av_packet = av_packet_alloc();
    }

    ~packet_raw_avcodec() {
      av_packet_free(&this->av_packet);
    }

    bool is_idr() override {
      return av_packet->flags & AV_PKT_FLAG_KEY;
    }

    int64_t frame_index() override {
      return av_packet->pts;
    }

    uint8_t *data() override {
      return av_packet->data;
    }

    size_t data_size() override {
      return av_packet->size;
    }

    AVPacket *av_packet;
  };

  struct packet_raw_generic: packet_raw_t {
    packet_raw_generic(std::vector<uint8_t> &&frame_data, int64_t frame_index, bool idr):
        frame_data {std::move(frame_data)},
        index {frame_index},
        idr {idr} {
    }

    bool is_idr() override {
      return idr;
    }

    int64_t frame_index() override {
      return index;
    }

    uint8_t *data() override {
      return frame_data.data();
    }

    size_t data_size() override {
      return frame_data.size();
    }

    std::vector<uint8_t> frame_data;
    int64_t index;
    bool idr;
  };

  using packet_t = std::unique_ptr<packet_raw_t>;

  struct hdr_info_raw_t {
    explicit hdr_info_raw_t(bool enabled):
        enabled {enabled},
        metadata {} {};
    explicit hdr_info_raw_t(bool enabled, const SS_HDR_METADATA &metadata):
        enabled {enabled},
        metadata {metadata} {};

    bool enabled;
    SS_HDR_METADATA metadata;
  };

  using hdr_info_t = std::unique_ptr<hdr_info_raw_t>;

  extern int active_hevc_mode;
  extern int active_av1_mode;
  extern bool last_encoder_probe_supported_ref_frames_invalidation;
  extern std::array<bool, 3> last_encoder_probe_supported_yuv444_for_codec;  // 0 - H.264, 1 - HEVC, 2 - AV1

  /**
   * @brief Decide whether a server-initiated on-demand IDR request should remain armed for
   *        another encoded frame (finding #3, bounded server-side IDR re-arm).
   *
   * The on-demand IDR flow (see encodeThread() in video.cpp) requests a keyframe by holding
   * AV_FRAME_FLAG_KEY on the frame handed to the encoder. Some encoders (observed with
   * VideoToolbox on a cold/negotiating session) do not honor the very next frame with an
   * actual keyframe packet - they silently emit a P-frame instead, and the client decodes
   * garbage until it re-requests.
   *
   * This is a bounded, event-driven re-arm: it keeps the KEY flag set for up to N frames
   * after a request, stopping the instant a real keyframe is observed (or the budget runs
   * out). It deliberately introduces NO periodicity - it only ever fires following a genuine
   * IDR request, and it emits at most one keyframe per request. This is what keeps it from
   * resurrecting the FIXED_GOP_SIZE metronomic-burst stutter that on-demand-only IDR (infinite
   * GOP) was introduced to cure.
   *
   * @param keyframe_emitted Whether the most recently encoded packet actually carried
   *                          AV_PKT_FLAG_KEY.
   * @param remaining         In/out re-arm budget. The caller sets this to N (e.g. 3) when a
   *                          new on-demand IDR is requested, and leaves it at 0 otherwise.
   *                          This function decrements it while still arming, and clamps it to
   *                          0 once the request is resolved (satisfied or exhausted).
   * @return true if the caller should keep the KEY flag armed for another frame (must NOT
   *         call request_normal_frame() yet); false once the request is resolved - either a
   *         keyframe arrived, or the re-arm budget is exhausted (caller should log the
   *         existing "gave up" alarm in that case) - and normal frame flags may be restored.
   */
  inline bool should_rearm_idr(bool keyframe_emitted, int &remaining) {
    if (remaining <= 0) {
      // Not currently arming an on-demand IDR request - nothing to do.
      return false;
    }
    if (keyframe_emitted) {
      // Request satisfied - clear the budget and stop arming.
      remaining = 0;
      return false;
    }
    if (--remaining <= 0) {
      // Exhausted the re-arm budget without a keyframe - give up.
      return false;
    }
    return true;
  }

  /**
   * @brief Thresholds for the VT backlog-plateau cure's reinit trigger (see
   *        should_reinit_for_backlog() below and
   *        docs/design/2026-07-14-vt-backlog-reinit-cure.md).
   *
   * All-constexpr defaults by design (owner prefers few knobs; see
   * config::video.vt.vt_reinit_cure, the cure's single kill-switch config key). Mirrors the
   * idr_rearm_budget in-code-constant pattern used for should_rearm_idr() above.
   */
  struct cure_params_t {
    /// == VT_SYNC_MAX_INFLIGHT - 1: the material ~33ms permanent plateau this cure targets.
    /// A single-frame residual (inflight == 1, ~16ms) is deliberately left alone - not worth an IDR.
    std::int64_t trigger_inflight = 2;
    /// Recovered encode calls measure ~1-3ms; loaded ones ~20-30ms (both well inside/outside the
    /// 14ms vt_sync_deadline_us). 10ms cleanly separates the two.
    double recovery_call_ms = 10.0;
    /// Consecutive 1s windows of fast calls required before firing - the primary anti-flap guard:
    /// a genuinely loaded encoder never sees 3 fast windows in a row.
    int recovery_windows = 3;
    /// Seconds since this encode session was built. Doubles as the inter-cure cooldown: every cure
    /// produces a fresh session with age 0, so this bound is simultaneously the age-guard AND the
    /// minimum spacing between cures - no persisted timestamp needed.
    double min_session_age_s = 30.0;
  };

  /**
   * @brief Decide whether the encode loop should trigger an intentional, one-off encoder-session
   *        rebuild to drain a backlog plateau left by the vt_sync_deadline_us cap (finding:
   *        docs/design/2026-07-14-vt-backlog-reinit-cure.md).
   *
   * Background: once `vt_sync_output`'s bounded pop lets a backlog form under load, ffmpeg's
   * classic encode2 calling convention makes that backlog permanent for the life of the encode
   * session - see the "backlog never drained" addendum in
   * docs/design/2026-07-13-vt-sync-output.md. The only lever that resets it is a fresh encoder
   * session, which the existing display-switch reinit path already knows how to build. This
   * predicate decides WHEN it is safe to cause one more such rebuild on purpose: the plateau must
   * still be present, the encoder must have demonstrably recovered (not just be between load
   * spikes), and enough time must have passed since the last rebuild that firing again can't
   * flap.
   *
   * Pure and deterministic - no I/O, no globals - so it is fully unit-testable independent of a
   * live VT session (see tests/unit/test_videotoolbox.cpp).
   *
   * @param enc_inflight Cumulative frames sent minus cumulative packets emitted so far this
   *                     session (the same "how many frames is the encoder holding right now"
   *                     gauge as the perf_trace enc_inflight counter).
   * @param recovered_windows Consecutive 1s windows in which this session's max per-call encode
   *                     latency stayed below params.recovery_call_ms - i.e. the encoder is no
   *                     longer genuinely loaded, only still holding a stale backlog.
   * @param session_age_s Seconds elapsed since this encode session was built.
   * @param params Thresholds (see cure_params_t).
   * @return true iff a cure-triggered rebuild should fire this tick.
   */
  inline bool should_reinit_for_backlog(std::int64_t enc_inflight, int recovered_windows, double session_age_s, const cure_params_t &params) {
    return enc_inflight >= params.trigger_inflight &&
           recovered_windows >= params.recovery_windows &&
           session_age_s >= params.min_session_age_s;
  }

  void capture(
    safe::mail_t mail,
    config_t config,
    void *channel_data
  );

  bool validate_encoder(encoder_t &encoder, bool expect_failure);

  /**
   * @brief Probe encoders and select the preferred encoder.
   * This is called once at startup and each time a stream is launched to
   * ensure the best encoder is selected. Encoder availability can change
   * at runtime due to all sorts of things from driver updates to eGPUs.
   *
   * @warning This is only safe to call when there is no client actively streaming.
   */
  int probe_encoders();

  // Several NTSC standard refresh rates are hardcoded here, because their
  // true rate requires a denominator of 1001. ffmpeg's av_d2q() would assume it could
  // reduce 29.97 to 2997/100 but this would be slightly wrong. We also include
  // support for 23.976 film in case someone wants to stream a film at the perfect
  // framerate.
  inline AVRational framerateX100_to_rational(const int framerateX100) {
    if (framerateX100 % 2997 == 0) {
      // Multiples of NTSC 29.97 e.g. 59.94, 119.88
      return AVRational {(framerateX100 / 2997) * 30000, 1001};
    }
    switch (framerateX100) {
      case 2397:  // the other weird NTSC framerate, assume these want 23.976 film
      case 2398:
        return AVRational {24000, 1001};
      default:
        // any other fractional rate can be reduced by ffmpeg. Max is set to 1 << 26 based on docs:
        // "rational numbers with |num| <= 1<<26 && |den| <= 1<<26 can be recovered exactly from their double representation"
        return av_d2q((double) framerateX100 / 100.0f, 1 << 26);
    }
  }

  /**
   * @brief Decide whether the encode loop's startup capture-stall warning should fire.
   *
   * The encode loop keeps the stream alive by re-encoding a dummy/stale frame whenever
   * the capture backend times out (the "minimum fps target" keepalive path). That path
   * is silent by design, so if capture never delivers a single real frame, the client
   * sees a healthy-looking stream of pure black with no diagnostic ever firing. This
   * predicate flags that condition once the loop has had a fair chance (~90 iterations,
   * i.e. ~3s at the 33ms keepalive timeout) to receive at least one real frame.
   *
   * @param real_frame_count Real (non-keepalive) frames popped so far this session.
   * @param loop_iterations Total encode-loop iterations so far this session.
   * @return true if zero real frames have arrived after the startup grace period.
   */
  inline bool should_warn_capture_stalled(std::uint64_t real_frame_count, std::uint64_t loop_iterations) {
    constexpr std::uint64_t startup_grace_iterations = 90;
    return real_frame_count == 0 && loop_iterations >= startup_grace_iterations;
  }

  /**
   * @brief Compute the mailbox pop timeout for the encode loop's frame-departure gap-filler
   *        (frame_departure_mode, docs/design/2026-07-13-cadence-phaselock.md §2.1).
   *
   * Modes 0/1 (off / capture-side v1 timer): byte-identical to today -- always wait up to the
   * existing keepalive timeout (`max_frametime`); the grid is never consulted. Mode 2
   * (encode-side v2-A phase-lock): wait only until the absolute departure grid deadline, so a
   * real frame that arrives is popped and emitted immediately (zero added latency vs. today)
   * and a deadline miss returns promptly for the caller to backfill on-grid.
   *
   * @param phaselock      true iff config::video.frame_departure_mode == 2.
   * @param now            Current steady_clock time, taken immediately before the pop() call.
   * @param next_deadline  The next absolute grid deadline (only meaningful when phaselock).
   * @param max_frametime  The existing v1/keepalive pop timeout (untouched in modes 0/1).
   * @return The duration to pass to `images->pop(...)`.
   */
  inline std::chrono::duration<double, std::milli> compute_departure_pop_timeout(
    bool phaselock,
    std::chrono::steady_clock::time_point now,
    std::chrono::steady_clock::time_point next_deadline,
    std::chrono::duration<double, std::milli> max_frametime
  ) {
    if (!phaselock) {
      return max_frametime;
    }

    auto remaining = std::chrono::duration<double, std::milli>(next_deadline - now);
    return remaining > std::chrono::duration<double, std::milli>::zero() ? remaining : std::chrono::duration<double, std::milli>::zero();
  }

  /**
   * @brief Advance the frame-departure phase-lock grid after handling one encode-loop
   *        iteration (docs/design/2026-07-13-cadence-phaselock.md §2.1).
   *
   * Real frames re-phase the grid to follow SCK's actual delivery cadence
   * (`emit_time + interval`) -- this is what gives real frames zero added latency. Backfills
   * (deadline misses) advance the grid by exactly one interval so a run of backfills stays
   * phase-stable instead of drifting by however long each `encode()` call took. The clamp
   * prevents the deadline from sitting in the past (which would otherwise fire a backfill on
   * every subsequent loop iteration -- "machine-gunning") if the encoder itself falls behind
   * (high `enc_over16`); acceptance criterion #1 in the design catches that condition and
   * routes it to encoder/resolution tuning, not pacer tuning.
   *
   * @param phaselock      true iff config::video.frame_departure_mode == 2. When false,
   *                       `next_deadline` is returned unchanged (modes 0/1 don't use the grid).
   * @param got_real_frame Whether this iteration emitted a real frame (vs. a deadline-miss
   *                       backfill / keepalive dup).
   * @param now            Current steady_clock time, taken immediately before this call (same
   *                       instant used to decide `got_real_frame`).
   * @param next_deadline  The grid deadline going into this iteration.
   * @param interval       1 / framerate, i.e. the target departure spacing.
   * @return The next absolute grid deadline.
   */
  inline std::chrono::steady_clock::time_point advance_departure_deadline(
    bool phaselock,
    bool got_real_frame,
    std::chrono::steady_clock::time_point now,
    std::chrono::steady_clock::time_point next_deadline,
    std::chrono::duration<double> interval
  ) {
    if (!phaselock) {
      return next_deadline;
    }

    auto interval_steady = std::chrono::duration_cast<std::chrono::steady_clock::duration>(interval);

    if (got_real_frame) {
      return now + interval_steady;
    }

    auto advanced = next_deadline + interval_steady;
    if (advanced < now) {
      // Clamp: never let the deadline sit in the past by more than one interval, so a
      // struggling encoder can't turn the pacer into a backfill machine-gun.
      advanced = now + interval_steady;
    }
    return advanced;
  }
}  // namespace video
