/**
 * @file tests/unit/test_videotoolbox.cpp
 * @brief Regression tests for the h264_videotoolbox encoder configuration used by Sunshine.
 *
 * macOS-only. Locks in two fixes to src/video.cpp:
 *   - commit 236d17a5: set the private "max_ref_frames" option (ffmpeg's h264_videotoolbox
 *     ignores AVCodecContext::refs) so client-negotiated reference-frame limits are honored.
 *   - the __APPLE__ gating added in 8864d911: AV_CODEC_FLAG_LOW_DELAY combined with
 *     max_ref_frames=1 makes lavc 62's h264_videotoolbox emit only every OTHER frame
 *     (in=120 out=60, pts 1,3,5,...). Sunshine now strips LOW_DELAY for the videotoolbox
 *     encoder specifically.
 *
 * These tests build an AVCodecContext directly with ffmpeg, mirroring exactly the flags/options
 * Sunshine's make_avcodec_encode_session() applies (see src/video.cpp ~line 1600-1680), rather
 * than exercising the full capture/encode pipeline. This keeps them fast (720p, no display
 * capture) while still exercising the real videotoolboxenc.c behavior the bugs live in.
 */
#include "../tests_common.h"
#include <chrono>
#include <thread>

#include <src/video.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
}

#include <algorithm>
#include <climits>
#include <cstring>
#include <vector>

// Deterministic state-machine regression guard for should_rearm_idr() (src/video.h), the
// bounded server-side IDR re-arm (finding #3). Pure logic, no encoder/platform dependency, so
// it builds and runs on every platform - this is the primary guard against regressing "the KEY
// flag is cleared after exactly one frame regardless of outcome". The VT-specific live-timing
// tests further below are macOS-only documentation/contract tests, not the deterministic guard.
TEST(IdrRearm, StateMachine) {
  // requested (attempt 1/3, P-frame) -> rearm -> (attempt 2/3, P-frame) -> rearm ->
  // (attempt 3/3, P-frame) -> give-up. N=3 is the total attempt budget (the initial request
  // plus up to 2 re-arm continuations), matching the runbook's "three consecutive misses
  // exhaust and clear" contract - NOT 3 re-arms on top of the initial attempt.
  int remaining = 3;  // set as if an on-demand IDR was just requested (budget = 3)
  EXPECT_TRUE(video::should_rearm_idr(/* keyframe_emitted = */ false, remaining)) << "attempt 1/3 missed - must keep arming";
  EXPECT_EQ(remaining, 2);
  EXPECT_TRUE(video::should_rearm_idr(false, remaining)) << "attempt 2/3 missed - must keep arming";
  EXPECT_EQ(remaining, 1);
  // Budget exhausted on the 3rd consecutive miss - must give up (not rearm again), clamped at 0.
  EXPECT_FALSE(video::should_rearm_idr(false, remaining)) << "attempt 3/3 missed - must give up, not rearm a 4th time";
  EXPECT_EQ(remaining, 0);
}

TEST(IdrRearm, KeyframeSatisfiesImmediately) {
  // requested -> keyframe -> no-rearm (satisfied on the very first frame, the common case)
  int remaining = 3;
  EXPECT_FALSE(video::should_rearm_idr(/* keyframe_emitted = */ true, remaining));
  EXPECT_EQ(remaining, 0) << "A satisfied request must clear the re-arm budget immediately";
}

TEST(IdrRearm, KeyframeMidRearmStopsEarly) {
  // requested -> P-frame -> rearm(1) -> keyframe -> no more re-arm. Stops the instant a real
  // keyframe shows up rather than burning the remaining budget or arming further frames -
  // this is what keeps the re-arm from turning into a periodic/every-frame keyframe burst.
  int remaining = 3;
  EXPECT_TRUE(video::should_rearm_idr(false, remaining));
  EXPECT_EQ(remaining, 2);
  EXPECT_FALSE(video::should_rearm_idr(true, remaining));
  EXPECT_EQ(remaining, 0);
}

TEST(IdrRearm, NotRequestedNeverRearms) {
  // not-requested -> no-rearm, regardless of whether the packet happens to be a keyframe
  // (e.g. a natural scene-change keyframe outside any on-demand request window). Guards
  // against the re-arm ever becoming periodic/every-frame behavior.
  int remaining = 0;
  EXPECT_FALSE(video::should_rearm_idr(false, remaining));
  EXPECT_EQ(remaining, 0);
  EXPECT_FALSE(video::should_rearm_idr(true, remaining));
  EXPECT_EQ(remaining, 0);
}

// Deterministic no-flap regression guard for should_reinit_for_backlog() (src/video.h), the VT
// backlog-plateau cure's pure trigger predicate (docs/design/2026-07-14-vt-backlog-reinit-cure.md
// §2). Pure logic, no encoder/platform dependency -- runs on every platform, same rationale as the
// IdrRearm suite above. These tests also drive the recovered_windows accumulator inline (the
// caller-side per-second increment/reset in encode_run()'s decision tick), since that accumulator
// is simple enough not to warrant its own extracted function, but its behavior is exactly what the
// design's Layer A synthetic sequences require covering.
TEST(BacklogCure, LoadedForeverNeverTriggers) {
  // Backlog present (inflight pinned at the plateau) but the encoder never actually recovers --
  // call_ms stays above the recovery threshold on every window. This is the primary anti-flap
  // case: the normal "plateau is steady state" condition must never fire on its own.
  video::cure_params_t params;
  int recovered_windows = 0;
  bool triggered = false;
  for (int window = 0; window < 100; ++window) {
    constexpr double loaded_call_ms = 25.0;  // above recovery_call_ms (10.0) -- genuinely loaded
    recovered_windows = (loaded_call_ms < params.recovery_call_ms) ? recovered_windows + 1 : 0;
    const double session_age_s = static_cast<double>(window + 1);  // climbs well past min_session_age_s
    if (video::should_reinit_for_backlog(/* enc_inflight = */ 2, recovered_windows, session_age_s, params)) {
      triggered = true;
    }
  }
  EXPECT_FALSE(triggered) << "A genuinely loaded encoder must never reach recovery_windows consecutive "
                             "fast windows, so the cure must never fire while real load is present";
}

TEST(BacklogCure, RecoveryUnderThreeWindowsNeverTriggers) {
  // Plateau present, call_ms goes fast for 1-2 windows at a time but load returns before the
  // 3rd consecutive recovered window -- must never fire. Age is fixed well past the cooldown so
  // it isn't the limiting factor; only the recovered-windows streak is under test.
  video::cure_params_t params;
  int recovered_windows = 0;
  bool triggered = false;
  const double call_ms_sequence[] = {2.0, 2.0, 25.0, 2.0, 2.0, 25.0, 2.0, 2.0};  // never 3 fast in a row
  for (double call_ms : call_ms_sequence) {
    recovered_windows = (call_ms < params.recovery_call_ms) ? recovered_windows + 1 : 0;
    if (video::should_reinit_for_backlog(/* enc_inflight = */ 2, recovered_windows, /* session_age_s = */ 1000.0, params)) {
      triggered = true;
    }
  }
  EXPECT_FALSE(triggered) << "Recovery streaks shorter than recovery_windows (3) must never trigger a reinit";
}

TEST(BacklogCure, PlateauRecoveredButYoungSessionNeverTriggers) {
  // Full recovery streak reached, but the session (since last build/rebuild) is younger than
  // min_session_age_s -- the age guard doubles as the inter-cure cooldown and must hold even
  // when the recovery signal alone looks ready to fire.
  video::cure_params_t params;
  int recovered_windows = 0;
  bool triggered = false;
  for (int window = 0; window < 10; ++window) {
    ++recovered_windows;  // fast every window
    const double session_age_s = window + 1.0;  // 1..10s, well under min_session_age_s (30)
    if (video::should_reinit_for_backlog(/* enc_inflight = */ 2, recovered_windows, session_age_s, params)) {
      triggered = true;
    }
  }
  EXPECT_FALSE(triggered) << "A session younger than min_session_age_s must not fire even with a full recovery streak";
}

TEST(BacklogCure, AgedSessionWaitsForThreeRecoveredWindowsThenFires) {
  // Session already old enough (age guard pre-satisfied); the recovery streak builds up one
  // window at a time. Must stay false until exactly the 3rd consecutive fast window.
  video::cure_params_t params;
  constexpr double session_age_s = 100.0;  // well past min_session_age_s -- isolates the streak requirement
  int recovered_windows = 0;
  ASSERT_FALSE(video::should_reinit_for_backlog(2, recovered_windows, session_age_s, params)) << "must not fire before any recovered window";
  ++recovered_windows;  // window 1/3 fast
  EXPECT_FALSE(video::should_reinit_for_backlog(2, recovered_windows, session_age_s, params)) << "1 recovered window must not be enough";
  ++recovered_windows;  // window 2/3 fast
  EXPECT_FALSE(video::should_reinit_for_backlog(2, recovered_windows, session_age_s, params)) << "2 recovered windows must not be enough";
  ++recovered_windows;  // window 3/3 fast
  EXPECT_TRUE(video::should_reinit_for_backlog(2, recovered_windows, session_age_s, params)) << "the 3rd consecutive recovered window must fire";
}

TEST(BacklogCure, PostFireCooldownBlocksImmediateRefire) {
  // Mirrors what actually resets after a cure-triggered rebuild in production (encode_run(): a
  // fresh encode session means session_age_s -> 0 and a fresh cure_recovered_windows local).
  // Even if recovered_windows still looks "ready" going into the new session, the age guard
  // (which doubles as the cooldown, per the design's §2c "cooldown is free") must block an
  // immediate re-fire, and must release again once min_session_age_s re-elapses.
  video::cure_params_t params;
  constexpr int recovered_windows = 3;  // still "recovered" carried into the fresh session's first tick
  EXPECT_FALSE(video::should_reinit_for_backlog(2, recovered_windows, /* session_age_s = */ 0.0, params))
    << "a brand-new session must not immediately re-fire";
  EXPECT_FALSE(video::should_reinit_for_backlog(2, recovered_windows, params.min_session_age_s - 1.0, params))
    << "must not fire 1s before the cooldown elapses";
  EXPECT_TRUE(video::should_reinit_for_backlog(2, recovered_windows, params.min_session_age_s, params))
    << "must fire again once min_session_age_s re-elapses";
}

TEST(BacklogCure, SingleFrameResidualNeverTriggers) {
  // inflight == 1 (~16ms residual, one bounded-wait deferral) is deliberately left alone by
  // design -- not worth an IDR. inflight == 0 (no backlog at all) obviously must not trigger
  // either.
  video::cure_params_t params;
  EXPECT_FALSE(video::should_reinit_for_backlog(1, params.recovery_windows, 1000.0, params))
    << "inflight==1 must never trigger regardless of recovery streak or age";
  EXPECT_FALSE(video::should_reinit_for_backlog(0, params.recovery_windows, 1000.0, params))
    << "inflight==0 (no backlog) must never trigger";
}

#ifdef __APPLE__

namespace {

  /**
   * @brief RAII helper that opens h264_videotoolbox configured the way Sunshine configures it
   *        (after the two fixes), with optional overrides for the specific behavior under test.
   */
  struct VtEncoderFixture {
    const AVCodec *codec = nullptr;
    AVCodecContext *ctx = nullptr;
    bool opened = false;

    // Dimensions kept small and gop kept at the standard Sunshine on-demand-IDR default
    // (infinite) unless a test overrides it, to keep tests fast.
    int width = 1280;
    int height = 720;
    int fps = 60;

    /**
     * @brief Build and open the codec context.
     * @param apply_low_delay If true, mirrors pre-fix behavior (LOW_DELAY kept) - used only by
     *        the documentation canary test.
     * @param gop_size Group-of-pictures size; Sunshine uses INT_MAX (on-demand IDR only) for
     *        encoders without FIXED_GOP_SIZE, which videotoolbox is.
     */
    bool setup(bool apply_low_delay, int gop_size = INT_MAX, bool sync_output = false, int bitrate = 6000000) {
      codec = avcodec_find_encoder_by_name("h264_videotoolbox");
      if (!codec) {
        return false;
      }

      ctx = avcodec_alloc_context3(codec);
      if (!ctx) {
        return false;
      }

      ctx->width = width;
      ctx->height = height;
      ctx->time_base = AVRational {1, fps};
      ctx->framerate = AVRational {fps, 1};
      ctx->pix_fmt = AV_PIX_FMT_YUV420P;
      ctx->bit_rate = bitrate;

      // Sunshine always disables B-frames (decoder-latency sensitive).
      ctx->max_b_frames = 0;

      ctx->gop_size = gop_size;
      ctx->keyint_min = gop_size;

      // Sunshine forcefully resets flags, then applies CLOSED_GOP (+ LOW_DELAY on non-VT
      // encoders only, since the fix in 8864d911).
      ctx->flags = 0;
      ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP;
      if (apply_low_delay) {
        ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
      }
      ctx->flags2 |= AV_CODEC_FLAG2_FAST;

      // client-negotiated single reference frame, applied exactly like
      // make_avcodec_encode_session(): ctx->refs plus the private option (fix in 236d17a5).
      ctx->refs = 1;
      av_opt_set_int(ctx->priv_data, "realtime", 1, 0);
      av_opt_set_int(ctx->priv_data, "prio_speed", 1, 0);
      if (av_opt_find(ctx->priv_data, "max_ref_frames", nullptr, 0, 0)) {
        av_opt_set_int(ctx->priv_data, "max_ref_frames", 1, 0);
      }

      if (sync_output) {
        if (av_opt_set_int(ctx->priv_data, "sync_output", 1, 0) < 0 ||
            av_opt_set_int(ctx->priv_data, "sync_deadline_us", 0, 0) < 0) {
          return false;
        }
      }
      opened = avcodec_open2(ctx, codec, nullptr) >= 0;
      return opened;
    }

    ~VtEncoderFixture() {
      if (ctx) {
        avcodec_free_context(&ctx);
      }
    }
  };

  /**
   * @brief Allocates a synthetic yuv420p frame of the fixture's dimensions, with per-frame
   *        varying content so the encoder can't trivially skip/dedupe it.
   */
  AVFrame *make_synthetic_frame(const VtEncoderFixture &fx) {
    AVFrame *frame = av_frame_alloc();
    frame->format = fx.ctx->pix_fmt;
    frame->width = fx.width;
    frame->height = fx.height;
    if (av_frame_get_buffer(frame, 0) < 0) {
      av_frame_free(&frame);
      return nullptr;
    }
    return frame;
  }

  void fill_frame(AVFrame *frame, int i) {
    for (int y = 0; y < frame->height; y++) {
      std::memset(frame->data[0] + static_cast<ptrdiff_t>(y) * frame->linesize[0], (y + i * 7) & 0xff, frame->width);
    }
    std::memset(frame->data[1], (i * 3) & 0xff, static_cast<size_t>(frame->linesize[1]) * frame->height / 2);
    std::memset(frame->data[2], 128, static_cast<size_t>(frame->linesize[2]) * frame->height / 2);
  }

}  // namespace

TEST(VideoToolboxEncoderTest, AdaptiveRebuildRetainsPtsAndStartsWithDecodableKeyframe) {
  // Synthetic buffers only. This exercises the packaged completion-driven VT
  // encoder across the same destruction/recreation boundary used by adaptive
  // encode_run, including retained frame indices and a new bitrate context.
  const auto start = std::chrono::steady_clock::now();
  int outputs = 0;
  for (int pass = 0; pass < 2; ++pass) {
    VtEncoderFixture fx;
    fx.width = 320; fx.height = 180;
    ASSERT_TRUE(fx.setup(false, INT_MAX, true, pass == 0 ? 2000000 : 1000000));
    AVFrame *frame = make_synthetic_frame(fx);
    ASSERT_NE(frame, nullptr);
    AVPacket *packet = av_packet_alloc();
    ASSERT_NE(packet, nullptr);
    for (int n = 1; n <= 8; ++n) {
      ASSERT_GE(av_frame_make_writable(frame), 0);
      fill_frame(frame, n + pass * 8);
      frame->pts = n + pass * 8;
      frame->pict_type = n == 1 ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
      if (n == 1) frame->flags |= AV_FRAME_FLAG_KEY;
      else frame->flags &= ~AV_FRAME_FLAG_KEY;
      ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0);
      ASSERT_EQ(avcodec_receive_packet(fx.ctx, packet), 0);
      EXPECT_EQ(packet->pts, frame->pts);
      if (n == 1) EXPECT_NE(packet->flags & AV_PKT_FLAG_KEY, 0);
      ++outputs;
      av_packet_unref(packet);
    }
    av_packet_free(&packet); av_frame_free(&frame);
  }
  EXPECT_EQ(outputs, 16);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
  RecordProperty("two_encoder_passes_ms", elapsed);
  EXPECT_LT(elapsed, 5000); // bounded synthetic gate; not a network latency claim
}

TEST(VideoToolboxEncoderTest, SyncOutputReturnsCurrentFrame) {
  VtEncoderFixture fx;
  ASSERT_TRUE(fx.setup(/* apply_low_delay = */ false, INT_MAX, /* sync_output = */ true));
  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr);
  AVPacket *packet = av_packet_alloc();
  ASSERT_NE(packet, nullptr);
  fill_frame(frame, 1);
  frame->pts = 1;
  ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0);
  EXPECT_EQ(avcodec_receive_packet(fx.ctx, packet), 0)
    << "sync_output must expose the submitted frame in this encode cycle";
  EXPECT_EQ(packet->pts, 1);
  av_packet_free(&packet);
  av_frame_free(&frame);
}

TEST(VideoToolboxEncoderTest, ReceiveCompletedPacketWithoutNextSubmission) {
  VtEncoderFixture fx;
  ASSERT_TRUE(fx.setup(/* apply_low_delay = */ false, INT_MAX, /* sync_output = */ false));
  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr);
  AVPacket *packet = av_packet_alloc();
  ASSERT_NE(packet, nullptr);
  fill_frame(frame, 1);
  frame->pts = 1;
  ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0);

  int result = AVERROR(EAGAIN);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
  while (std::chrono::steady_clock::now() < deadline) {
    result = avcodec_receive_packet(fx.ctx, packet);
    if (result != AVERROR(EAGAIN)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  EXPECT_EQ(result, 0) << "Completed VT output must be retrievable without submitting another frame";
  if (result == 0) {
    EXPECT_EQ(packet->pts, 1);
  }
  av_packet_free(&packet);
  av_frame_free(&frame);
}

TEST(VideoToolboxEncoderTest, NoFrameHalvingWithSunshineFlags) {
  VtEncoderFixture fx;
  if (!avcodec_find_encoder_by_name("h264_videotoolbox")) {
    GTEST_SKIP() << "h264_videotoolbox not registered in this ffmpeg build";
  }
  if (!fx.setup(/* apply_low_delay = */ false)) {
    GTEST_SKIP() << "Failed to open h264_videotoolbox (VideoToolbox unavailable in this environment)";
  }

  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr) << "Failed to allocate synthetic frame buffer";
  AVPacket *pkt = av_packet_alloc();
  ASSERT_NE(pkt, nullptr);

  int frames_sent = 0;
  std::vector<int64_t> received_pts;

  for (int i = 1; i <= 120; i++) {
    ASSERT_GE(av_frame_make_writable(frame), 0);
    fill_frame(frame, i);
    frame->pts = i;

    ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0) << "send_frame failed at frame " << i;
    frames_sent++;

    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      received_pts.push_back(pkt->pts);
      av_packet_unref(pkt);
    }
  }

  // Flush.
  avcodec_send_frame(fx.ctx, nullptr);
  while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
    received_pts.push_back(pkt->pts);
    av_packet_unref(pkt);
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);

  ASSERT_EQ(frames_sent, 120);
  ASSERT_EQ(received_pts.size(), 120u) << "Encoder dropped/halved output packets - LOW_DELAY + "
                                           "max_ref_frames=1 frame-halving regression (fix 8864d911) may have reappeared.";

  std::vector<int64_t> sorted_pts = received_pts;
  std::sort(sorted_pts.begin(), sorted_pts.end());
  for (size_t idx = 0; idx < sorted_pts.size(); idx++) {
    EXPECT_EQ(sorted_pts[idx], static_cast<int64_t>(idx + 1)) << "pts sequence is not strictly consecutive 1..120 at index " << idx;
  }
}

// OPTIONAL CANARY: documents that, as of lavc 62, LOW_DELAY + max_ref_frames=1 still halves
// h264_videotoolbox output. This is *expected* upstream behavior we work around (not a Sunshine
// bug), so the test tolerates either outcome (60 == still broken, 120 == upstream fixed it) and
// only fails if some third, unexplained packet count shows up. If this ever reports 120 (i.e.
// RecordProperty says "fixed"), it means the LOW_DELAY strip in src/video.cpp for the
// videotoolbox encoder could potentially be reverted - re-verify before doing so.
TEST(VideoToolboxEncoderTest, LowDelayHalvingStillBroken_Documented) {
  VtEncoderFixture fx;
  if (!avcodec_find_encoder_by_name("h264_videotoolbox")) {
    GTEST_SKIP() << "h264_videotoolbox not registered in this ffmpeg build";
  }
  if (!fx.setup(/* apply_low_delay = */ true)) {
    GTEST_SKIP() << "Failed to open h264_videotoolbox (VideoToolbox unavailable in this environment)";
  }

  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr) << "Failed to allocate synthetic frame buffer";
  AVPacket *pkt = av_packet_alloc();
  ASSERT_NE(pkt, nullptr);

  int out_count = 0;
  int send_err = 0;
  for (int i = 1; i <= 120 && send_err == 0; i++) {
    ASSERT_GE(av_frame_make_writable(frame), 0);
    fill_frame(frame, i);
    frame->pts = i;
    // On paravirtualized VT (GitHub Actions macOS runners) the LOW_DELAY combination
    // doesn't halve - the encoder hard-errors mid-stream (observed: -12908 at frame 5).
    // That is yet another form of "still broken", not a test failure.
    send_err = avcodec_send_frame(fx.ctx, frame);
    if (send_err < 0) {
      break;
    }
    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      out_count++;
      av_packet_unref(pkt);
    }
  }
  if (send_err == 0) {
    avcodec_send_frame(fx.ctx, nullptr);
    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      out_count++;
      av_packet_unref(pkt);
    }
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);

  RecordProperty("lavc_low_delay_output_count", out_count);
  if (send_err < 0) {
    RecordProperty("lavc_low_delay_behavior", "encoder-error-still-broken");
    GTEST_SKIP() << "LOW_DELAY path hard-errored mid-encode (err " << send_err
                 << " after " << out_count << " packets) - still broken, in a different way";
  }
  if (out_count == 120) {
    RecordProperty("lavc_low_delay_behavior", "fixed-upstream");
  } else if (out_count == 60) {
    RecordProperty("lavc_low_delay_behavior", "still-halved-as-documented");
  }

  // Only fail on a clean encode whose count is neither the documented-broken nor the
  // hoped-for-fixed value - that would indicate a new, unexplained behavior worth investigating.
  EXPECT_TRUE(out_count == 60 || out_count == 120) << "Unexpected output packet count " << out_count << " (expected 60 [documented halving] or 120 [upstream fixed])";
}

TEST(VideoToolboxEncoderTest, OnDemandIdrHonored) {
  VtEncoderFixture fx;
  if (!avcodec_find_encoder_by_name("h264_videotoolbox")) {
    GTEST_SKIP() << "h264_videotoolbox not registered in this ffmpeg build";
  }
  // Infinite GOP: Sunshine relies entirely on on-demand IDR requests (request_idr_frame()),
  // never a periodic keyframe interval, for encoders without FIXED_GOP_SIZE.
  if (!fx.setup(/* apply_low_delay = */ false, /* gop_size = */ INT_MAX)) {
    GTEST_SKIP() << "Failed to open h264_videotoolbox (VideoToolbox unavailable in this environment)";
  }

  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr) << "Failed to allocate synthetic frame buffer";
  AVPacket *pkt = av_packet_alloc();
  ASSERT_NE(pkt, nullptr);

  std::vector<int64_t> keyframe_pts;

  for (int i = 1; i <= 120; i++) {
    ASSERT_GE(av_frame_make_writable(frame), 0);
    fill_frame(frame, i);
    frame->pts = i;

    // Mirrors platf::avcodec_encode_device_t::request_idr_frame() (src/video.cpp ~line 350):
    // force an IDR at frame 60 exactly like Sunshine does when a client requests one on-demand.
    if (i == 60) {
      frame->pict_type = AV_PICTURE_TYPE_I;
      frame->flags |= AV_FRAME_FLAG_KEY;
    } else {
      frame->pict_type = AV_PICTURE_TYPE_NONE;
      frame->flags &= ~AV_FRAME_FLAG_KEY;
    }

    ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0) << "send_frame failed at frame " << i;

    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      if (pkt->flags & AV_PKT_FLAG_KEY) {
        keyframe_pts.push_back(pkt->pts);
      }
      av_packet_unref(pkt);
    }
  }

  avcodec_send_frame(fx.ctx, nullptr);
  while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
    if (pkt->flags & AV_PKT_FLAG_KEY) {
      keyframe_pts.push_back(pkt->pts);
    }
    av_packet_unref(pkt);
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);

  ASSERT_EQ(keyframe_pts.size(), 2u) << "Expected exactly 2 keyframes (initial IDR at pts=1 + on-demand IDR at pts=60) with infinite GOP";
  std::sort(keyframe_pts.begin(), keyframe_pts.end());
  EXPECT_EQ(keyframe_pts[0], 1) << "First frame of an infinite-GOP stream must always be a keyframe";
  EXPECT_EQ(keyframe_pts[1], 60) << "On-demand IDR request at frame 60 was not honored";
}

// DOCUMENTATION CANARY - NOT a pass/fail contract on the shipped N=3 re-arm budget.
//
// This measures h264_videotoolbox's actual send-to-matching-keyframe-packet latency on a
// warmed-up session (mirroring a real mid-stream on-demand IDR request), the scenario finding
// #3's bounded re-arm targets. It intentionally does NOT assert the keyframe arrives within
// should_rearm_idr()'s N=3 budget, because empirically (measured while writing this test, this
// Mac, this ffmpeg build) it does not:
//
//   IMPORTANT CAVEAT FOR THE ARCHITECT / LIVE SESSION (read before relying on N=3):
//   With LOW_DELAY stripped for h264_videotoolbox (fix 8864d911, required to avoid the
//   frame-halving bug - see NoFrameHalvingWithSunshineFlags above), this encoder is deeply
//   pipelined: after warm-up it settles into steady-state 1-packet-out-per-1-frame-in, but
//   delayed by a roughly constant ~12 frames. The frame that had AV_FRAME_FLAG_KEY set DOES
//   eventually emerge with AV_PKT_FLAG_KEY - VT honors the request correctly - but not for
//   ~12 more avcodec_send_frame() calls, nowhere near should_rearm_idr()'s N=3 (or even N=8)
//   window. Two consequences the live throwaway-window test (runbook WS1) should specifically
//   watch for:
//     1. The re-arm will very likely still "give up" (exhaust remaining) and log "Encoder did
//        not produce IDR frame when requested!" on effectively every on-demand request on this
//        class of hardware - the log-rate PASS criterion (~0) may not be met by N=3 alone.
//     2. Because should_rearm_idr() keeps re-asserting request_idr_frame() on every armed
//        iteration, a 3-frame budget forces 3 *separate* real frames (not just the first) to
//        be encoded as I-frames before giving up - a small burst of forced keyframes clustered
//        at the request, not the "at most one keyframe per request" the design intends.
//   This does not invalidate the bounded/event-driven shape of the fix (still correctly never
//   periodic), but it means N=3 may be undersized for this hardware's real pipeline depth, and/or
//   the per-call synchronous keyframe_emitted check may need to become a pts-tracked check
//   instead of "whatever packet drains on this call". Flagging for architect review before or
//   during the live session rather than silently enlarging N in a pre-stage worker change.
//
// The test itself just bounds sanity (keyframe shows up at all within a generous ceiling) and
// records the measured latency for the record; it is deterministic on a given host, not flaky.
TEST(VideoToolboxEncoderTest, OnDemandIdrPipelineLatencyDocumented) {
  VtEncoderFixture fx;
  if (!avcodec_find_encoder_by_name("h264_videotoolbox")) {
    GTEST_SKIP() << "h264_videotoolbox not registered in this ffmpeg build";
  }
  if (!fx.setup(/* apply_low_delay = */ false, /* gop_size = */ INT_MAX)) {
    GTEST_SKIP() << "Failed to open h264_videotoolbox (VideoToolbox unavailable in this environment)";
  }

  AVFrame *frame = make_synthetic_frame(fx);
  ASSERT_NE(frame, nullptr) << "Failed to allocate synthetic frame buffer";
  AVPacket *pkt = av_packet_alloc();
  ASSERT_NE(pkt, nullptr);

  // Warm up with ordinary frames first, mirroring a live session's steady flow - the mid-session
  // scenario finding #3 actually targets, as opposed to the very first frame of a session (which
  // is trivially always a keyframe by h.264 convention and never exercises this bug).
  constexpr int warmup_frames = 20;
  for (int w = 1; w <= warmup_frames; w++) {
    ASSERT_GE(av_frame_make_writable(frame), 0);
    fill_frame(frame, w);
    frame->pts = w;
    frame->pict_type = AV_PICTURE_TYPE_NONE;
    frame->flags &= ~AV_FRAME_FLAG_KEY;
    ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0);
    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      av_packet_unref(pkt);
    }
  }

  // Generous ceiling well past the measured ~12-frame pipeline depth - this is a sanity bound
  // ("does a keyframe ever come out"), not the shipped N=3 budget under test.
  constexpr int generous_ceiling = 40;
  int frames_until_keyframe = 0;
  bool keyframe_seen = false;

  for (int i = warmup_frames + 1; i <= warmup_frames + generous_ceiling && !keyframe_seen; i++) {
    ASSERT_GE(av_frame_make_writable(frame), 0);
    fill_frame(frame, i);
    frame->pts = i;
    // Request the on-demand IDR on exactly the first post-warmup frame only, then send normal
    // frames after it - mirrors the ONE encoder-side request the client actually issues (does
    // not itself re-arm here; re-arm behavior is covered separately by IdrRearm.StateMachine).
    if (i == warmup_frames + 1) {
      frame->pict_type = AV_PICTURE_TYPE_I;
      frame->flags |= AV_FRAME_FLAG_KEY;
    } else {
      frame->pict_type = AV_PICTURE_TYPE_NONE;
      frame->flags &= ~AV_FRAME_FLAG_KEY;
    }

    ASSERT_GE(avcodec_send_frame(fx.ctx, frame), 0) << "send_frame failed at frame " << i;

    while (avcodec_receive_packet(fx.ctx, pkt) == 0) {
      if (pkt->flags & AV_PKT_FLAG_KEY) {
        keyframe_seen = true;
        frames_until_keyframe = i - (warmup_frames + 1) + 1;
      }
      av_packet_unref(pkt);
    }
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);

  RecordProperty("idr_pipeline_latency_frames", frames_until_keyframe);
  EXPECT_TRUE(keyframe_seen) << "VideoToolbox never produced a keyframe for the requested frame "
                                 "within a generous "
                              << generous_ceiling << "-frame window - this would indicate VT is "
                                                      "genuinely dropping the request, not just delaying it";
  if (keyframe_seen) {
    EXPECT_GT(frames_until_keyframe, 3) << "Pipeline latency dropped to <=3 frames on this host - "
                                            "if this regresses lower and stays low, should_rearm_idr()'s "
                                            "N=3 budget may now be adequate and this comment/caveat can "
                                            "be revisited; if you see this fail, that's good news, not a bug.";
  }
}

#endif  // __APPLE__

#ifdef __APPLE__
TEST(VideoToolboxDependency, PatchedFFmpegIsLinked) {
  EXPECT_STREQ(av_version_info(), "9.0.2") << "Skylight requires its pinned patched FFmpeg on macOS";
  EXPECT_EQ(AV_VERSION_MAJOR(avcodec_version()), 63u);
  for (const char *name : {"h264_videotoolbox", "hevc_videotoolbox"}) {
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    ASSERT_NE(codec, nullptr) << name;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    ASSERT_NE(context, nullptr);
    ASSERT_NE(context->priv_data, nullptr);
    EXPECT_NE(av_opt_find(context->priv_data, "sync_output", nullptr, 0, 0), nullptr) << name;
    EXPECT_NE(av_opt_find(context->priv_data, "sync_deadline_us", nullptr, 0, 0), nullptr) << name;
    avcodec_free_context(&context);
  }
}
#endif
