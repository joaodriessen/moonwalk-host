/**
 * @file tests/unit/test_video.cpp
 * @brief Test src/video.*.
 */
#include "../tests_common.h"

#include <src/video.h>

using namespace std::chrono_literals;

struct EncoderTest: PlatformTestSuite, testing::WithParamInterface<video::encoder_t *> {
  void SetUp() override {
    auto &encoder = *GetParam();
    if (!video::validate_encoder(encoder, false)) {
      // Encoder failed validation,
      // if it's software - fail, otherwise skip
      if (encoder.name == "software") {
        FAIL() << "Software encoder not available";
      } else {
        GTEST_SKIP() << "Encoder not available";
      }
    }
  }
};

INSTANTIATE_TEST_SUITE_P(
  EncoderVariants,
  EncoderTest,
  testing::Values(
#if !defined(__APPLE__)
    &video::nvenc,
#endif
#ifdef _WIN32
    &video::amdvce,
    &video::quicksync,
#endif
#if defined(__linux__) || defined(__FreeBSD__)
    &video::vaapi,
#endif
#ifdef __APPLE__
    &video::videotoolbox,
#endif
    &video::software
  ),
  [](const auto &info) {
    return std::string(info.param->name);
  }
);

TEST_P(EncoderTest, ValidateEncoder) {
  // todo:: test something besides fixture setup
}

struct FramerateX100Test: testing::TestWithParam<std::tuple<std::int32_t, AVRational>> {};

TEST_P(FramerateX100Test, Run) {
  const auto &[x100, expected] = GetParam();
  auto res = video::framerateX100_to_rational(x100);
  ASSERT_EQ(0, av_cmp_q(res, expected)) << "expected "
                                        << expected.num << "/" << expected.den
                                        << ", got "
                                        << res.num << "/" << res.den;
}

INSTANTIATE_TEST_SUITE_P(
  FramerateX100Tests,
  FramerateX100Test,
  testing::Values(
    std::make_tuple(2397, AVRational {24000, 1001}),
    std::make_tuple(2398, AVRational {24000, 1001}),
    std::make_tuple(2500, AVRational {25, 1}),
    std::make_tuple(2997, AVRational {30000, 1001}),
    std::make_tuple(3000, AVRational {30, 1}),
    std::make_tuple(5994, AVRational {60000, 1001}),
    std::make_tuple(6000, AVRational {60, 1}),
    std::make_tuple(11988, AVRational {120000, 1001}),
    std::make_tuple(23976, AVRational {240000, 1001}),  // future NTSC 240hz?
    std::make_tuple(9498, AVRational {4749, 50})  // from my LG 27GN950
  )
);

struct CaptureStallTest: testing::TestWithParam<std::tuple<std::uint64_t, std::uint64_t, bool>> {};

TEST_P(CaptureStallTest, Run) {
  const auto &[real_frame_count, loop_iterations, expected] = GetParam();
  ASSERT_EQ(expected, video::should_warn_capture_stalled(real_frame_count, loop_iterations));
}

INSTANTIATE_TEST_SUITE_P(
  CaptureStallTests,
  CaptureStallTest,
  testing::Values(
    // No iterations yet: never warn, regardless of real frame count.
    std::make_tuple(0, 0, false),
    // Under the ~90-iteration (~3s) startup grace period: don't warn yet even with 0 real frames.
    std::make_tuple(0, 89, false),
    // At/after the grace period with zero real frames: warn.
    std::make_tuple(0, 90, true),
    std::make_tuple(0, 1000, true),
    // Any real frame at all, even just one, means capture is alive: never warn.
    std::make_tuple(1, 90, false),
    std::make_tuple(1, 1000, false),
    std::make_tuple(5, 5, false)
  )
);

// Frame-departure phase-lock pure logic (docs/design/2026-07-13-cadence-phaselock.md §2.1).
// A fixed reference time_point anchors all cases so durations below are easy to reason about.
namespace {
  const auto kDepartureT0 = std::chrono::steady_clock::time_point(std::chrono::seconds(1000));
}  // namespace

TEST(DeparturePopTimeoutTest, ModeOffAlwaysReturnsMaxFrametimeRegardlessOfGrid) {
  // Modes 0/1 (phaselock == false): must be byte-identical to today -- always max_frametime,
  // completely ignoring now/next_deadline. This is the mode-1-identity guarantee's unit-level
  // check: the pop-timeout computation can never observe the grid unless phaselock is true.
  std::chrono::duration<double, std::milli> max_frametime {33.3};

  ASSERT_EQ(max_frametime, video::compute_departure_pop_timeout(false, kDepartureT0, kDepartureT0 + 5ms, max_frametime));
  ASSERT_EQ(max_frametime, video::compute_departure_pop_timeout(false, kDepartureT0 + 1000ms, kDepartureT0, max_frametime));
  ASSERT_EQ(max_frametime, video::compute_departure_pop_timeout(false, kDepartureT0, kDepartureT0 - 50ms, max_frametime));
}

TEST(DeparturePopTimeoutTest, PhaselockWaitsForRemainingTimeUntilDeadline) {
  std::chrono::duration<double, std::milli> max_frametime {33.3};
  auto next_deadline = kDepartureT0 + 19170us;  // interval(16.667ms) + guard(2.5ms)

  auto timeout = video::compute_departure_pop_timeout(true, kDepartureT0, next_deadline, max_frametime);
  ASSERT_NEAR(19.17, timeout.count(), 0.01);
}

TEST(DeparturePopTimeoutTest, PhaselockReturnsZeroOnceDeadlineHasPassed) {
  std::chrono::duration<double, std::milli> max_frametime {33.3};
  auto next_deadline = kDepartureT0 - 5ms;  // already in the past

  auto timeout = video::compute_departure_pop_timeout(true, kDepartureT0, next_deadline, max_frametime);
  auto zero_timeout = std::chrono::duration<double, std::milli>::zero();
  ASSERT_EQ(zero_timeout, timeout);
}

TEST(DepartureDeadlineTest, ModeOffLeavesDeadlineUntouched) {
  // Modes 0/1: next_deadline must pass through unchanged no matter what got_real_frame says --
  // the grid is never consulted or mutated outside phaselock.
  auto next_deadline = kDepartureT0 + 100ms;

  ASSERT_EQ(next_deadline, video::advance_departure_deadline(false, true, kDepartureT0, next_deadline, 16667us));
  ASSERT_EQ(next_deadline, video::advance_departure_deadline(false, false, kDepartureT0 + 500ms, next_deadline, 16667us));
}

TEST(DepartureDeadlineTest, RealFrameRePhasesToArrivalPlusInterval) {
  std::chrono::duration<double> interval {16667us};
  auto stale_deadline = kDepartureT0 - 200ms;  // grid was way behind; a real frame re-phases it

  auto next = video::advance_departure_deadline(true, /*got_real_frame=*/true, kDepartureT0, stale_deadline, interval);
  ASSERT_EQ(kDepartureT0 + std::chrono::duration_cast<std::chrono::steady_clock::duration>(interval), next);
}

TEST(DepartureDeadlineTest, BackfillAdvancesGridByExactlyOneIntervalWhenOnTime) {
  std::chrono::duration<double> interval {16667us};
  auto prev_deadline = kDepartureT0;
  auto now = kDepartureT0 + 1ms;  // encode() took ~1ms; grid is not behind

  auto next = video::advance_departure_deadline(true, /*got_real_frame=*/false, now, prev_deadline, interval);
  ASSERT_EQ(prev_deadline + std::chrono::duration_cast<std::chrono::steady_clock::duration>(interval), next);
}

TEST(DepartureDeadlineTest, BackfillClampsInsteadOfMachineGunningWhenEncoderFallsBehind) {
  // If the encoder itself is slow (high enc_over16), a naive prev_deadline + interval could
  // still land in the past, which would make every subsequent iteration an instant backfill.
  // The clamp must pin the next deadline to now + interval instead.
  std::chrono::duration<double> interval {16667us};
  auto prev_deadline = kDepartureT0;
  auto now = kDepartureT0 + 200ms;  // encode() took far longer than one interval

  auto next = video::advance_departure_deadline(true, /*got_real_frame=*/false, now, prev_deadline, interval);
  ASSERT_EQ(now + std::chrono::duration_cast<std::chrono::steady_clock::duration>(interval), next);
}
