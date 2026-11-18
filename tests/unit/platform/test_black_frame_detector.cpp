/**
 * @file tests/unit/platform/test_black_frame_detector.cpp
 * @brief Test src/platform/macos/black_frame_detector.h -- the pure, CVPixelBuffer-free predicate
 *        and state machine deciding whether a captured frame is suspect-black and, if so, when to
 *        self-heal (docs/design/2026-07-12-black-screen-permanent-fix.md §3 "Fix for Mode 4").
 * @details No CVPixelBuffer/ObjC dependency -- this header has zero macOS-API surface, so both the
 *          luminance predicate and the session state machine are fully exercisable here even though
 *          display.mm (their only production caller) is macOS-only.
 */
#include "../../tests_common.h"

#include <src/platform/macos/black_frame_detector.h>

using namespace platf::macos;

// ── sample_is_suspect_black ────────────────────────────────────────────────

TEST(BlackFrameDetectorPredicate, AllZeroSampleIsBlack) {
  std::vector<std::uint8_t> sample(25, 0);
  EXPECT_TRUE(sample_is_suspect_black(sample, 2));
}

TEST(BlackFrameDetectorPredicate, AllAtThresholdIsBlack) {
  // "At or below" the threshold counts -- boundary inclusive.
  std::vector<std::uint8_t> sample(25, 2);
  EXPECT_TRUE(sample_is_suspect_black(sample, 2));
}

TEST(BlackFrameDetectorPredicate, OneBrightPointAmongManyDarkIsNotBlack) {
  // This is the load-bearing false-positive guard: a real desktop (menu bar, cursor, dock icon,
  // wallpaper texture) almost always lights up at least one point in a spread-out grid, even on an
  // otherwise very dark scene. A single sample above threshold must veto the whole frame.
  std::vector<std::uint8_t> sample(25, 0);
  sample[12] = 200;  // e.g. the grid point landing on a menu-bar glyph or cursor
  EXPECT_FALSE(sample_is_suspect_black(sample, 2));
}

TEST(BlackFrameDetectorPredicate, JustAboveThresholdIsNotBlack) {
  std::vector<std::uint8_t> sample(25, 3);
  EXPECT_FALSE(sample_is_suspect_black(sample, 2));
}

TEST(BlackFrameDetectorPredicate, EmptySampleIsNeverBlack) {
  // No data extracted (e.g. buffer lock failed) must never read as "black" -- that would fire the
  // self-heal on a sampler bug instead of a real black frame.
  std::vector<std::uint8_t> sample;
  EXPECT_FALSE(sample_is_suspect_black(sample, 2));
}

TEST(BlackFrameDetectorPredicate, DarkButLiveSceneIsNotBlack) {
  // A dark wallpaper / night-mode desktop: mostly near-zero with scattered dim-but-nonzero detail
  // (anti-aliased text edges, a subtle gradient). None of it is "black-but-valid" content -- the
  // false-positive risk case §3 explicitly calls out.
  std::vector<std::uint8_t> sample = {0, 0, 1, 0, 0, 1, 0, 0, 5, 0, 0, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0};
  EXPECT_FALSE(sample_is_suspect_black(sample, 2));
}

// ── BlackFrameDetector::should_sample_next_frame cadence ───────────────────

TEST(BlackFrameDetectorCadence, SamplesEveryFrameDuringStartupWindow) {
  BlackFrameDetector detector(/*startup_window_frames=*/5, 3, 10, 5);
  for (int i = 0; i < 5; ++i) {
    EXPECT_TRUE(detector.should_sample_next_frame()) << "frame " << i;
  }
}

TEST(BlackFrameDetectorCadence, SamplesOnlyOnStrideAfterStartupWindow) {
  BlackFrameDetector detector(/*startup_window_frames=*/2, 100, /*periodic_sample_stride=*/3, 100);
  // Frames 1-2: startup window, always sampled.
  EXPECT_TRUE(detector.should_sample_next_frame());
  EXPECT_TRUE(detector.should_sample_next_frame());
  // Frame 3: first post-startup frame, 3 % 3 == 0 -> sampled.
  EXPECT_TRUE(detector.should_sample_next_frame());
  // Frames 4-5: not on the stride -> skipped entirely (negligible steady-state cost).
  EXPECT_FALSE(detector.should_sample_next_frame());
  EXPECT_FALSE(detector.should_sample_next_frame());
  // Frame 6: back on the stride.
  EXPECT_TRUE(detector.should_sample_next_frame());
}

TEST(BlackFrameDetectorCadence, NeverSamplesAgainOnceSelfHealed) {
  BlackFrameDetector detector(/*startup_window_frames=*/5, /*startup_consecutive_black=*/2, 1, 1);
  ASSERT_TRUE(detector.should_sample_next_frame());
  ASSERT_TRUE(detector.record_sample(true).should_self_heal == false);
  ASSERT_TRUE(detector.should_sample_next_frame());
  auto decision = detector.record_sample(true);
  ASSERT_TRUE(decision.should_self_heal);
  ASSERT_TRUE(detector.has_self_healed());

  // No matter how many more frames arrive, the detector must never ask to sample -- or fire --
  // again this session. This is the "ONCE per session (don't loop-thrash)" requirement.
  for (int i = 0; i < 50; ++i) {
    EXPECT_FALSE(detector.should_sample_next_frame());
  }
}

// ── BlackFrameDetector::record_sample self-heal decision ───────────────────

TEST(BlackFrameDetectorDecision, FiresAfterConsecutiveBlackInStartupWindow) {
  BlackFrameDetector detector(/*startup_window_frames=*/30, /*startup_consecutive_black=*/3, 30, 100);
  detector.should_sample_next_frame();
  EXPECT_FALSE(detector.record_sample(true).should_self_heal);
  detector.should_sample_next_frame();
  EXPECT_FALSE(detector.record_sample(true).should_self_heal);
  detector.should_sample_next_frame();
  EXPECT_TRUE(detector.record_sample(true).should_self_heal);
}

TEST(BlackFrameDetectorDecision, ANonBlackFrameResetsTheConsecutiveCount) {
  // Guards against a slow trickle of isolated black frames (e.g. one dropped/corrupt frame every
  // so often on an otherwise healthy stream) ever accumulating into a false self-heal.
  BlackFrameDetector detector(/*startup_window_frames=*/30, /*startup_consecutive_black=*/3, 30, 100);
  for (int i = 0; i < 20; ++i) {
    detector.should_sample_next_frame();
    bool is_black = (i % 2 == 0);  // black, not-black, black, not-black, ... never 3 in a row
    auto decision = detector.record_sample(is_black);
    EXPECT_FALSE(decision.should_self_heal) << "iteration " << i;
  }
  EXPECT_FALSE(detector.has_self_healed());
}

TEST(BlackFrameDetectorDecision, PeriodicPathRequiresStricterConsecutiveRunThanStartup) {
  // Startup window is tiny (2 frames) so we quickly move to the periodic path, which requires a
  // much longer consecutive-black run (5) before firing -- deliberately more conservative than
  // startup, since it fires anytime mid-session rather than only in the just-connected window.
  BlackFrameDetector detector(/*startup_window_frames=*/2, /*startup_consecutive_black=*/100, /*periodic_sample_stride=*/1, /*periodic_consecutive_black=*/5);

  // Burn through the startup window with NON-black frames, so the consecutive-black counter is
  // back at zero by the time we reach the periodic path below (isolating what we're testing).
  detector.should_sample_next_frame();
  detector.record_sample(false);
  detector.should_sample_next_frame();
  detector.record_sample(false);

  // Now in the periodic path: fewer than 5 consecutive black samples must not fire.
  for (int i = 0; i < 4; ++i) {
    detector.should_sample_next_frame();
    EXPECT_FALSE(detector.record_sample(true).should_self_heal) << "periodic sample " << i;
  }
  // The 5th consecutive periodic black sample fires.
  detector.should_sample_next_frame();
  EXPECT_TRUE(detector.record_sample(true).should_self_heal);
}

TEST(BlackFrameDetectorDecision, DoesNotFireOnSustainedNonBlackSoak) {
  // A minute-long soak of legitimately non-black content (dark desktop or otherwise) across both
  // the startup and periodic paths must never fire, no matter how long it runs.
  BlackFrameDetector detector;
  for (int i = 0; i < 5000; ++i) {
    if (detector.should_sample_next_frame()) {
      auto decision = detector.record_sample(false);
      EXPECT_FALSE(decision.should_self_heal);
    }
  }
  EXPECT_FALSE(detector.has_self_healed());
}
