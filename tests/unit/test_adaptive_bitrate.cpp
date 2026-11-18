#include <gtest/gtest.h>
#include <src/adaptive_bitrate.h>

using namespace std::chrono_literals;

namespace {
video::frame_fec_status feedback(unsigned frame, unsigned data_received, unsigned parity_received = 0) {
  return {frame, 100, 20, data_received, parity_received, 120 - data_received - parity_received, 0, 1};
}
void severe_pressure(video::adaptive_bitrate_controller &controller, unsigned &frame) {
  for (int second = 0; second <= 10; second += 2)
    controller.report(feedback(frame++, 10), std::chrono::steady_clock::time_point {} + std::chrono::seconds(second));
}
}

TEST(AdaptiveBitrateCapacity, SevereLossAtMeasuredCeilingReachesLowRateWithinPressureWindow) {
  video::adaptive_bitrate_controller controller(41388);
  const auto start = std::chrono::steady_clock::time_point {};
  for (unsigned index = 0; index < 6; ++index) {
    EXPECT_TRUE(controller.report(feedback(index + 1, 50), start + std::chrono::seconds(index * 2)));
    if (index == 4) EXPECT_LE(controller.target(), 1500);
  }
  EXPECT_EQ(controller.target(), 1000);
  EXPECT_FALSE(controller.report(feedback(7, 10), start + 12s));
  EXPECT_EQ(controller.target(), 1000);
}

TEST(AdaptiveBitrateCapacity, SeverityBoundaryCountsParityAndPreservesOrdinaryLossFactors) {
  const auto now = std::chrono::steady_clock::time_point {};
  video::adaptive_bitrate_controller boundary(20000), severe(20000), ordinary(20000), recovered(20000);
  ASSERT_TRUE(boundary.report(feedback(1, 55, 20), now));
  EXPECT_EQ(boundary.target(), 15000); // Exactly75% of needed data remains ordinary.
  ASSERT_TRUE(severe.report(feedback(1, 54, 20), now));
  EXPECT_EQ(severe.target(), 10000);
  ASSERT_TRUE(ordinary.report(feedback(1, 70, 20), now));
  EXPECT_EQ(ordinary.target(), 15000);
  ASSERT_TRUE(recovered.report(feedback(1, 80, 20), now));
  EXPECT_EQ(recovered.target(), 18000);
}

TEST(AdaptiveBitrateCapacity, SevereFeedbackStillRespectsCadenceStaleAndDuplicateGuards) {
  video::adaptive_bitrate_controller controller(41388);
  const auto now = std::chrono::steady_clock::time_point {};
  ASSERT_TRUE(controller.report(feedback(1, 50), now));
  EXPECT_EQ(controller.target(), 20694);
  EXPECT_FALSE(controller.report(feedback(2, 50), now + 1s));
  EXPECT_FALSE(controller.report(feedback(1, 50), now + 2s));
  EXPECT_FALSE(controller.report(feedback(2, 50), now + 2s));
  EXPECT_EQ(controller.target(), 20694);
  ASSERT_TRUE(controller.report(feedback(3, 50), now + 2s));
  EXPECT_EQ(controller.target(), 10347);
}

TEST(AdaptiveBitrateCapacity, RecoveryWaitsForCleanWindowAndProbesRelativeToLowTarget) {
  video::adaptive_bitrate_controller controller(41388);
  unsigned frame = 1;
  severe_pressure(controller, frame);
  ASSERT_EQ(controller.target(), 1000);
  const auto now = std::chrono::steady_clock::time_point {};
  for (int second = 11; second < 20; ++second)
    EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + std::chrono::seconds(second)));
  EXPECT_EQ(controller.target(), 1000);
  ASSERT_TRUE(controller.report(feedback(frame++, 100, 20), now + 20s));
  EXPECT_EQ(controller.target(), 1250);
  for (int second = 21; second < 25; ++second)
    EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + std::chrono::seconds(second)));
  ASSERT_TRUE(controller.report(feedback(frame++, 100, 20), now + 25s));
  EXPECT_EQ(controller.target(), 1562);
}

TEST(AdaptiveBitrateCapacity, SilenceAndRepeatedFeedbackNeverCountAsCleanRecovery) {
  video::adaptive_bitrate_controller controller(41388);
  unsigned frame = 1;
  severe_pressure(controller, frame);
  ASSERT_EQ(controller.target(), 1000);
  const auto now = std::chrono::steady_clock::time_point {};
  EXPECT_FALSE(controller.report(feedback(frame, 100, 20), now + 70s));
  EXPECT_FALSE(controller.report(feedback(frame, 100, 20), now + 80s));
  EXPECT_FALSE(controller.report(feedback(frame - 1, 100, 20), now + 80s));
  ++frame;
  EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + 81s));
  for (int second = 82; second < 91; ++second)
    EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + std::chrono::seconds(second)));
  ASSERT_TRUE(controller.report(feedback(frame++, 100, 20), now + 91s));
  EXPECT_EQ(controller.target(), 1250);
}

TEST(AdaptiveBitrateCapacity, CleanRecoveryEventuallyReachesCeilingWithoutLargeLowRateJumps) {
  video::adaptive_bitrate_controller controller(41388);
  unsigned frame = 1;
  severe_pressure(controller, frame);
  ASSERT_EQ(controller.target(), 1000);
  const auto now = std::chrono::steady_clock::time_point {};
  for (int second = 11; second <= 160; ++second) {
    const int previous = controller.target();
    controller.report(feedback(frame++, 100, 20), now + std::chrono::seconds(second));
    EXPECT_LE(controller.target() - previous, 2069);
    EXPECT_GE(controller.target(), previous);
    EXPECT_LE(controller.target(), controller.ceiling());
  }
  EXPECT_EQ(controller.target(), controller.ceiling());
}

TEST(AdaptiveBitrateCapacity, RequestedCeilingBelowAbsoluteFloorRemainsHonored) {
  video::adaptive_bitrate_controller controller(500);
  const auto now = std::chrono::steady_clock::time_point {};
  EXPECT_FALSE(controller.report(feedback(1, 0), now));
  EXPECT_EQ(controller.target(), 500);
}

TEST(AdaptiveBitrateCapacity, MeasuredCatastrophicLossSurvivesMilderAndCleanCadenceCallbacks) {
  video::adaptive_bitrate_controller controller(41388);
  const auto now = std::chrono::steady_clock::time_point {};
  ASSERT_TRUE(controller.report({769, 6, 2, 4, 0, 2, 0, 1}, now));
  ASSERT_EQ(controller.target(), 20694);
  EXPECT_FALSE(controller.report({775, 199, 40, 40, 6, 153, 0, 1}, now + 50ms));
  EXPECT_FALSE(controller.report({776, 58, 12, 7, 1, 50, 0, 1}, now + 500ms));
  EXPECT_FALSE(controller.report({777, 20, 4, 3, 0, 17, 0, 1}, now + 1100ms));
  EXPECT_FALSE(controller.report(feedback(778, 80, 20), now + 1500ms));
  ASSERT_TRUE(controller.report(feedback(779, 100, 20), now + 2s));
  EXPECT_EQ(controller.target(), 5173);
  EXPECT_FALSE(controller.report({780, 14, 3, 1, 1, 12, 0, 1}, now + 3500ms));
  ASSERT_TRUE(controller.report(feedback(781, 80, 20), now + 4s));
  EXPECT_EQ(controller.target(), 1293);
}

TEST(AdaptiveBitrateCapacity, CatastrophicFirstReportAndRecentPendingLossQuarterTheTarget) {
  video::adaptive_bitrate_controller controller(41388);
  const auto now = std::chrono::steady_clock::time_point {};
  ASSERT_TRUE(controller.report({775, 199, 40, 40, 6, 153, 0, 1}, now));
  EXPECT_EQ(controller.target(), 10347);
  EXPECT_FALSE(controller.report({776, 58, 12, 7, 1, 50, 0, 1}, now + 1500ms));
  ASSERT_TRUE(controller.report(feedback(777, 100, 20), now + 2s));
  EXPECT_EQ(controller.target(), 2586);
}

TEST(AdaptiveBitrateCapacity, QuarterThresholdIsStrictAndCountsReceivedParity) {
  const auto now = std::chrono::steady_clock::time_point {};
  video::adaptive_bitrate_controller boundary(20000), below(20000), parity(20000);
  ASSERT_TRUE(boundary.report(feedback(1, 25), now));
  EXPECT_EQ(boundary.target(), 10000);
  ASSERT_TRUE(below.report(feedback(1, 24), now));
  EXPECT_EQ(below.target(), 5000);
  ASSERT_TRUE(parity.report(feedback(1, 20, 5), now));
  EXPECT_EQ(parity.target(), 10000);
}

TEST(AdaptiveBitrateCapacity, StaleAndDuplicateLossCannotPopulateOrRefreshPendingSeverity) {
  const auto now = std::chrono::steady_clock::time_point {};
  video::adaptive_bitrate_controller controller(20000);
  ASSERT_TRUE(controller.report(feedback(10, 50), now));
  EXPECT_FALSE(controller.report(feedback(11, 10), now + 100ms));
  EXPECT_FALSE(controller.report(feedback(11, 10), now + 1500ms));
  EXPECT_FALSE(controller.report(feedback(9, 10), now + 1800ms));
  EXPECT_FALSE(controller.report(feedback(12, 100, 20), now + 2s));
  EXPECT_EQ(controller.target(), 10000);
  EXPECT_FALSE(controller.report(feedback(12, 10), now + 2100ms));
  EXPECT_FALSE(controller.report(feedback(11, 10), now + 2200ms));
  ASSERT_TRUE(controller.report(feedback(13, 80, 20), now + 4s));
  EXPECT_EQ(controller.target(), 9000);
}

TEST(AdaptiveBitrateCapacity, PendingLossExpiresAfterOneSecondWithoutLoss) {
  const auto now = std::chrono::steady_clock::time_point {};
  video::adaptive_bitrate_controller expired(20000);
  ASSERT_TRUE(expired.report(feedback(1, 50), now));
  EXPECT_FALSE(expired.report(feedback(2, 10), now + 100ms));
  EXPECT_FALSE(expired.report(feedback(3, 100, 20), now + 1101ms));
  ASSERT_TRUE(expired.report(feedback(4, 80, 20), now + 2s));
  EXPECT_EQ(expired.target(), 9000);
}

TEST(AdaptiveBitrateCapacity, AnyFreshLossKeepsWindowSeverityForExactlyOneSecond) {
  const auto now = std::chrono::steady_clock::time_point {};
  for (const auto eligible : {2000ms, 2001ms}) {
    video::adaptive_bitrate_controller controller(20000);
    ASSERT_TRUE(controller.report(feedback(1, 50), now));
    EXPECT_FALSE(controller.report(feedback(2, 10), now + 100ms));
    EXPECT_FALSE(controller.report(feedback(3, 80, 20), now + 1s));
    EXPECT_EQ(controller.report(feedback(4, 100, 20), now + eligible), eligible == 2000ms);
    EXPECT_EQ(controller.target(), eligible == 2000ms ? 2500 : 10000);
  }
}

TEST(AdaptiveBitrateCapacity, CleanCallbackApplyingPendingLossStillNeedsFullCleanRecoveryWindow) {
  video::adaptive_bitrate_controller controller(20000);
  const auto now = std::chrono::steady_clock::time_point {};
  ASSERT_TRUE(controller.report(feedback(1, 50), now));
  EXPECT_FALSE(controller.report(feedback(2, 10), now + 1500ms));
  ASSERT_TRUE(controller.report(feedback(3, 100, 20), now + 2s));
  ASSERT_EQ(controller.target(), 2500);
  unsigned frame = 4;
  for (int ms = 2500; ms < 11500; ms += 500)
    EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + std::chrono::milliseconds(ms)));
  ASSERT_TRUE(controller.report(feedback(frame++, 100, 20), now + 11500ms));
  EXPECT_EQ(controller.target(), 3125);
  for (int ms = 12000; ms < 16500; ms += 500)
    EXPECT_FALSE(controller.report(feedback(frame++, 100, 20), now + std::chrono::milliseconds(ms)));
  ASSERT_TRUE(controller.report(feedback(frame++, 100, 20), now + 16500ms));
  EXPECT_EQ(controller.target(), 3906);
}

namespace {
std::string automatic_report(std::uint32_t target, std::uint32_t pace = 0, std::uint8_t drain = 0, std::uint32_t sequence = 0, std::uint8_t version = 1) {
  std::string bytes(20, '\0');
  auto put = [&](unsigned at, std::uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) bytes[at + i] = char((value >> (8 * i)) & 0xFF);
  };
  bytes[0] = char(version);
  bytes[1] = char(drain);
  put(4, target);
  put(8, pace);
  put(16, sequence);
  return bytes;
}
video::automatic_bitrate_report parsed(const std::string &bytes) {
  return *video::parse_automatic_bitrate_report(bytes);
}
}

TEST(AutomaticBitrateReport, RejectsAnythingMalformed) {
  EXPECT_TRUE(video::parse_automatic_bitrate_report(automatic_report(20000)));
  EXPECT_FALSE(video::parse_automatic_bitrate_report(automatic_report(20000, 0, 0, 0, 2)));
  EXPECT_FALSE(video::parse_automatic_bitrate_report(automatic_report(0)));
  EXPECT_FALSE(video::parse_automatic_bitrate_report(automatic_report(2000000)));
  EXPECT_FALSE(video::parse_automatic_bitrate_report(automatic_report(20000).substr(0, 19)));
}

TEST(AutomaticBitrateReport, FollowsTheClientWithinTheHostsLimits) {
  video::adaptive_bitrate_controller controller(41388, 80000);
  controller.client_report(parsed(automatic_report(64000)));
  EXPECT_EQ(controller.target(), 64000); // Above the negotiated rate, below the host's ceiling.
  controller.client_report(parsed(automatic_report(200000)));
  EXPECT_EQ(controller.target(), 80000);
  controller.client_report(parsed(automatic_report(10)));
  EXPECT_EQ(controller.target(), 1000);
}

TEST(AutomaticBitrateReport, TakesOverFromLossFeedback) {
  video::adaptive_bitrate_controller controller(20000, 80000);
  const auto now = std::chrono::steady_clock::time_point {};
  controller.client_report(parsed(automatic_report(20000)));
  EXPECT_FALSE(controller.report(feedback(1, 10), now));
  EXPECT_EQ(controller.target(), 20000);
}

TEST(AutomaticBitrateReport, OnlyPacesWhenAsked) {
  video::adaptive_bitrate_controller controller(20000, 80000);
  EXPECT_EQ(controller.pacing_kbps(), 20000); // An older client still gets the old pacing.
  controller.client_report(parsed(automatic_report(20000)));
  EXPECT_EQ(controller.pacing_kbps(), 0);
  controller.client_report(parsed(automatic_report(20000, 60000)));
  EXPECT_EQ(controller.pacing_kbps(), 60000);
}

TEST(AutomaticBitrateReport, EachDrainRequestIsHonouredOnce) {
  video::adaptive_bitrate_controller controller(20000, 80000);
  controller.client_report(parsed(automatic_report(20000, 0, 2, 7)));
  EXPECT_TRUE(controller.take_drain_frame());
  EXPECT_TRUE(controller.take_drain_frame());
  EXPECT_FALSE(controller.take_drain_frame());
  controller.client_report(parsed(automatic_report(20000, 0, 2, 7))); // Repeated report, same request.
  EXPECT_FALSE(controller.take_drain_frame());
  controller.client_report(parsed(automatic_report(20000, 0, 1, 8)));
  EXPECT_TRUE(controller.take_drain_frame());
}

TEST(AutomaticFrameBudget, FollowsTheTargetByLeavingOutFramesAboveIt) {
  video::automatic_frame_budget budget;
  auto now = std::chrono::steady_clock::time_point {} + 1h;
  int sent = 0;
  // A 2 Mbps target against an encoder stuck producing 11 Mbps (23 KB a frame at 60 fps).
  for (int frame = 0; frame < 600; ++frame) {
    now += std::chrono::microseconds(16667);
    if (budget.allow(now, 2000, 60)) { budget.spent(23000); ++sent; }
  }
  EXPECT_LE(sent, 180); // Ten seconds at 1.25 x 2 Mbps is 136 frames, plus the ten-a-second floor's slack.
  EXPECT_GE(sent, 100); // Never under ten frames a second.
}

TEST(AutomaticFrameBudget, LeavesAnEncoderThatKeepsToItsTargetAlone) {
  video::automatic_frame_budget budget;
  auto now = std::chrono::steady_clock::time_point {} + 1h;
  budget.allow(now, 40000, 60);
  for (int frame = 0; frame < 600; ++frame) {
    now += std::chrono::microseconds(16667);
    ASSERT_TRUE(budget.allow(now, 40000, 60));
    budget.spent(40000000 / 8 / 60);
  }
}

TEST(AutomaticBitrateRebuild, OnlyAfterARealDipAndARealRecovery) {
  EXPECT_TRUE(video::rebuild_after_dip(30000, 7000, 41000, 41000, 30s, 6s));
  EXPECT_FALSE(video::rebuild_after_dip(13000, 7000, 41000, 41000, 30s, 6s)); // Not doubled yet.
  EXPECT_FALSE(video::rebuild_after_dip(30000, 7000, 41000, 41000, 5s, 6s));  // Too soon after the last one.
  EXPECT_FALSE(video::rebuild_after_dip(30000, 7000, 41000, 41000, 30s, 2s)); // Still coming down.
  EXPECT_FALSE(video::rebuild_after_dip(64000, 41000, 41000, 41000, 30s, 6s)); // Climbing with no dip.
  EXPECT_FALSE(video::rebuild_after_dip(80000, 38000, 41000, 41000, 30s, 6s)); // Too small a dip to matter.
  EXPECT_TRUE(video::rebuild_after_dip(52000, 26000, 26000, 41000, 30s, 6s)); // Built during the dip.
  EXPECT_FALSE(video::rebuild_after_dip(64000, 41000, 41000, 41000, 30s, 6s));
}
