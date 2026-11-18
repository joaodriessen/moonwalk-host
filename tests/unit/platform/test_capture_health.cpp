#include <gtest/gtest.h>
#include <src/platform/macos/capture_health.h>

using platf::macos::capture_health;
using platf::macos::capture_state;

TEST(CaptureHealth, CachedDeliveryCannotSatisfyFirstCaptureReadiness) {
  capture_health health;
  auto owner = health.begin();
  health.cached(owner);
  auto snapshot = health.snapshot();
  EXPECT_EQ(snapshot.frames, 0u);
  EXPECT_EQ(snapshot.cached_frames, 1u);
  EXPECT_FALSE(snapshot.ready());
  EXPECT_EQ(snapshot.state, capture_state::starting);
}

TEST(CaptureHealth, CompleteNeedsImageAndIdleDoesNotCountAsNewContent) {
  capture_health health;
  auto owner = health.begin();
  EXPECT_FALSE(health.note(owner, capture_state::complete, false));
  EXPECT_FALSE(health.snapshot().ready());
  EXPECT_TRUE(health.note(owner, capture_state::complete, true));
  EXPECT_TRUE(health.snapshot().ready());
  EXPECT_FALSE(health.note(owner, capture_state::idle, true));
  health.cached(owner);
  EXPECT_TRUE(health.snapshot().ready());
  EXPECT_EQ(health.snapshot().frames, 1u);
  EXPECT_EQ(health.snapshot().cached_frames, 1u);
}

TEST(CaptureHealth, BlankSuspendedStoppedAndUnknownAreNotHealthy) {
  for (auto state : {capture_state::blank, capture_state::suspended,
                    capture_state::stopped, capture_state::unknown, capture_state::failed}) {
    capture_health health;
    auto owner = health.begin();
    health.note(owner, capture_state::complete, true);
    EXPECT_FALSE(health.note(owner, state, true));
    health.cached(owner);
    EXPECT_FALSE(health.snapshot().ready());
    EXPECT_EQ(health.snapshot().frames, 1u);
    EXPECT_EQ(health.snapshot().state, state);
  }
}

TEST(CaptureHealth, ReplacementRejectsLateEventsAndResetsReadiness) {
  capture_health health;
  auto old = health.begin();
  health.note(old, capture_state::complete, true);
  auto current = health.begin();
  EXPECT_NE(old, current);
  EXPECT_FALSE(health.note(old, capture_state::stopped, false));
  health.cached(old);
  EXPECT_FALSE(health.snapshot().ready());
  EXPECT_EQ(health.snapshot().state, capture_state::starting);
  EXPECT_EQ(health.snapshot().frames, 0u);
  EXPECT_EQ(health.snapshot().cached_frames, 0u);
  EXPECT_TRUE(health.note(current, capture_state::complete, true));
}
