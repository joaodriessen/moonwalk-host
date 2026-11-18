/**
 * @file src/platform/macos/black_frame_detector.h
 * @brief Pure predicate + state machine for the Mode-4 black-frame safety net (no ObjC/Foundation
 *        dependency), so the detection/self-heal DECISION can be exercised directly from a plain
 *        C++ unit test without a live capture session or CVPixelBuffer.
 * @details docs/design/2026-07-12-black-screen-permanent-fix.md §3 "Fix for Mode 4 — black-content
 *          safety net (conservative, logged, gated)". This is the last-resort backstop for anything
 *          Modes 1-3 don't cover (a wedged ghost, an unforeseen path): the only content gate before
 *          this fix was null-vs-non-null CMSampleBuffer (sc_capture.m:424, display.mm:41-44) — a
 *          black-but-valid frame looked perfectly healthy.
 *
 *          Deliberately conservative per the doc's explicit warning: "a self-heal that
 *          false-triggers on legitimately dark content is worse than the bug". Two independent
 *          guards keep it that way:
 *            1. `sample_is_suspect_black()` requires EVERY sampled point (not an average, not a
 *               majority) to be at/below a strict near-zero threshold. A real desktop — even a
 *               dark wallpaper or a screensaver — has a menu bar, cursor, dock, or subtle gradient
 *               that puts at least one grid point above threshold; a truly black/no-signal frame
 *               does not.
 *            2. `BlackFrameDetector` additionally requires a run of CONSECUTIVE suspect-black
 *               samples before firing, and fires the self-heal AT MOST ONCE per instance (i.e. once
 *               per capture session — one instance is owned per capture session, see display.mm).
 *
 *          Sampling cadence (`should_sample_next_frame`) is also part of the "negligible per-frame
 *          cost" requirement: every frame in the short startup window, then only a sparse periodic
 *          sample afterward, then never again once healed — so steady-state healthy streaming does
 *          essentially zero extra work.
 *
 *          Note on the doc's periodic-check idle-input gate ("no input activity for T seconds"):
 *          this file does not have an input-activity signal threaded to it (adding one would touch
 *          input.mm/session-lifetime plumbing outside this fix's scope). The periodic path instead
 *          compensates with a much longer required consecutive-black run than the startup path
 *          (several seconds of sustained black at the default sampling stride) — per the doc's own
 *          "when in doubt, don't self-heal" guidance, this trades a slower periodic reaction for
 *          not needing that extra plumbing.
 */
#pragma once

#include <cstdint>
#include <vector>

namespace platf::macos {

  // Strict "is this sampled frame black" predicate. `sample` is a small set of already-extracted,
  // 0-255-normalized luminance-ish values (see display.mm's sample_luminance_grid, which reads the
  // luma/Y plane directly for planar formats or max(B,G,R) for packed BGRA). A frame is suspect-black
  // ONLY when every sampled point is at or below `max_luminance` -- see file-level doc comment for
  // why "all points" (not average/majority) is the load-bearing false-positive guard.
  inline bool sample_is_suspect_black(const std::vector<std::uint8_t> &sample, std::uint8_t max_luminance) {
    if (sample.empty()) {
      // No data extracted (e.g. buffer lock failed, degenerate 0x0 buffer) -- never treat "no
      // signal from the sampler" as "black signal"; that would fire on sampler bugs, not black
      // frames.
      return false;
    }

    for (auto value : sample) {
      if (value > max_luminance) {
        return false;
      }
    }

    return true;
  }

  // Session-scoped state machine deciding WHEN to self-heal from a sequence of per-frame
  // black/not-black verdicts. Pure C++ (no CVPixelBuffer/ObjC dependency) so it is fully
  // unit-testable without a live capture session. One instance is owned per sc_display_t/
  // av_display_t capture session (constructed fresh in the display() factory on every connect and
  // reconnect -- see display.mm), so every counter below is naturally reset each session; the
  // once-per-session self-heal budget below is therefore also a once-per-CONNECT budget, never a
  // process-lifetime one.
  class BlackFrameDetector {
  public:
    struct Decision {
      bool should_self_heal {false};
    };

    // Defaults per docs/design/2026-07-12-black-screen-permanent-fix.md §3 Mode 4:
    //  - startup_window_frames: "the first N frames of a session" -- ~1s at a 30fps target.
    //  - startup_consecutive_black: must be black for over half the startup window, consecutively,
    //    before firing -- a single dropped/transient frame never trips it.
    //  - periodic_sample_stride: after the startup window, sample only 1-in-this-many frames so
    //    steady-state healthy streaming pays essentially no extra cost.
    //  - periodic_consecutive_black: the periodic path requires this many consecutive *sampled*
    //    hits (so, at the default stride and a 30fps target, several seconds of sustained black)
    //    before firing -- deliberately much stricter than startup, see file-level doc comment on
    //    the idle-input-gate substitution.
    explicit BlackFrameDetector(
      int startup_window_frames = 30,
      int startup_consecutive_black = 15,
      int periodic_sample_stride = 30,
      int periodic_consecutive_black = 5
    ):
        startup_window_frames_(startup_window_frames),
        startup_consecutive_black_(startup_consecutive_black),
        periodic_sample_stride_(periodic_sample_stride),
        periodic_consecutive_black_(periodic_consecutive_black) {
    }

    // Call once per delivered frame, BEFORE doing any pixel work. Returns whether this particular
    // frame should be sampled at all: true for every frame in the startup window, then only
    // 1-in-`periodic_sample_stride` afterward, and never once already healed this session. Keeps
    // the steady-state cost of this net at ~zero -- callers must skip the CVPixelBuffer lock/read
    // entirely when this returns false.
    bool should_sample_next_frame() {
      if (self_healed_) {
        return false;
      }

      ++frame_index_;
      in_startup_window_ = frame_index_ <= startup_window_frames_;

      if (in_startup_window_) {
        return true;
      }

      return periodic_sample_stride_ > 0 && (frame_index_ % periodic_sample_stride_) == 0;
    }

    // Feed the sampled verdict for a frame `should_sample_next_frame()` said to sample. Returns
    // whether to fire the (once-per-session) self-heal now.
    Decision record_sample(bool is_suspect_black) {
      Decision decision;

      if (self_healed_) {
        return decision;
      }

      consecutive_black_ = is_suspect_black ? consecutive_black_ + 1 : 0;

      const int threshold = in_startup_window_ ? startup_consecutive_black_ : periodic_consecutive_black_;
      if (threshold > 0 && consecutive_black_ >= threshold) {
        self_healed_ = true;
        decision.should_self_heal = true;
      }

      return decision;
    }

    bool has_self_healed() const {
      return self_healed_;
    }

    int consecutive_black() const {
      return consecutive_black_;
    }

  private:
    int startup_window_frames_;
    int startup_consecutive_black_;
    int periodic_sample_stride_;
    int periodic_consecutive_black_;

    long frame_index_ {0};
    int consecutive_black_ {0};
    bool in_startup_window_ {true};
    bool self_healed_ {false};
  };

}  // namespace platf::macos
