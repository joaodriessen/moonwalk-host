#include <gtest/gtest.h>
#include <src/adaptive_video_pacer.h>

using namespace std::chrono_literals;

namespace {
using clock_type = std::chrono::steady_clock;
constexpr std::size_t payload_bytes = 1360;
constexpr std::size_t wire_bytes = 1432; // RTP/video, encryption and IPv4 UDP/IP included.
}

TEST(AdaptiveVideoPacing, LowRatePacketsFitWireBudgetIncludingFecAndHeaders) {
  stream::adaptive_video_pacer pacer;
  auto now = clock_type::time_point {};
  const auto start = now;
  const auto budget = stream::adaptive_video_pacer::wire_rate_bps(1000, 20, wire_bytes, payload_bytes);
  EXPECT_GT(budget, 1200000u);
  for (int packet = 0; packet < 1000; ++packet) {
    ASSERT_EQ(stream::adaptive_video_pacer::batch_size(1000, 20, wire_bytes, payload_bytes, 45), 1u);
    now = pacer.due(now);
    pacer.sent(now, 1, 1000, 20, wire_bytes, payload_bytes);
  }
  const auto duration = pacer.due(now) - start;
  EXPECT_GE(duration, 9s);
  const auto observed_bps = 1000.0 * wire_bytes * 8 / std::chrono::duration<double>(duration).count();
  EXPECT_LE(observed_bps, double(budget));
  EXPECT_GT(observed_bps, double(budget) * 0.999);
}

TEST(AdaptiveVideoPacing, FrameAndFecBlockBoundariesKeepTheLastPacketDebt) {
  stream::adaptive_video_pacer pacer;
  const auto now = clock_type::time_point {};
  pacer.sent(now, 1, 1000, 20, wire_bytes, payload_bytes);
  const auto next_frame = pacer.due(now);
  EXPECT_GE(next_frame - now, 9ms);
  pacer.sent(next_frame, 1, 1000, 20, wire_bytes, payload_bytes);
  EXPECT_GE(pacer.due(next_frame) - now, 18ms);
}

TEST(AdaptiveVideoPacing, LateWakeupDoesNotAccumulateCreditForACatchupBurst) {
  stream::adaptive_video_pacer pacer;
  const auto start = clock_type::time_point {};
  pacer.sent(start, 1, 1000, 20, wire_bytes, payload_bytes);
  const auto late = start + 1s;
  EXPECT_EQ(pacer.due(late), late);
  pacer.sent(late, 1, 1000, 20, wire_bytes, payload_bytes);
  EXPECT_GE(pacer.due(late) - late, 9ms);
}

TEST(AdaptiveVideoPacing, TargetCutChangesTheNextBatchWithoutResettingDebt) {
  stream::adaptive_video_pacer pacer;
  const auto start = clock_type::time_point {};
  pacer.sent(start, 4, 40000, 20, wire_bytes, payload_bytes);
  const auto next = pacer.due(start);
  EXPECT_GT(next, start);
  EXPECT_EQ(stream::adaptive_video_pacer::batch_size(1000, 20, wire_bytes, payload_bytes, 45), 1u);
  pacer.sent(next, 1, 1000, 20, wire_bytes, payload_bytes);
  EXPECT_GE(pacer.due(next) - next, 9ms);
}

TEST(AdaptiveVideoPacing, HighRateBatchingKeepsOneMillisecondAndExistingPlatformLimits) {
  const auto batch = stream::adaptive_video_pacer::batch_size(41388, 20, wire_bytes, payload_bytes, 45);
  EXPECT_GE(batch, 4u);
  EXPECT_LE(batch, 5u);
  EXPECT_EQ(stream::adaptive_video_pacer::batch_size(2000000000, 255, wire_bytes, payload_bytes, 45), 45u);
  EXPECT_EQ(stream::adaptive_video_pacer::batch_size(2000000000, 255, wire_bytes, payload_bytes, 64), 64u);
}

TEST(AdaptiveVideoPacing, SeparateSessionsCannotBorrowEachOthersDeadline) {
  stream::adaptive_video_pacer slow, other;
  const auto start = clock_type::time_point {};
  slow.sent(start, 1, 1000, 20, wire_bytes, payload_bytes);
  EXPECT_GT(slow.due(start), start);
  EXPECT_EQ(other.due(start), start);
}

TEST(AdaptiveVideoPacing, Ipv6EncryptionAndLowRequestedRatesKeepProgressAndBudget) {
  stream::adaptive_video_pacer pacer;
  const auto start = clock_type::time_point {};
  constexpr auto ipv6_wire = wire_bytes + 20;
  EXPECT_GT(stream::adaptive_video_pacer::wire_rate_bps(500, 20, ipv6_wire, payload_bytes),
            stream::adaptive_video_pacer::wire_rate_bps(500, 20, wire_bytes, payload_bytes));
  pacer.sent(start, 1, 500, 20, ipv6_wire, payload_bytes);
  EXPECT_GE(pacer.due(start) - start, 18ms);
  EXPECT_LT(pacer.due(start) - start, 19ms);
}
