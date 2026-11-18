#include <gtest/gtest.h>
#include <src/platform/macos/audio_capture_policy.h>
#include <src/platform/macos/capture_display_binding.h>
#include <src/platform/macos/click_tracker.h>

TEST(MacAudioChannelContract, NativeAliasesAreStereoAndExplicitInputsRetainMultichannel) {
  using namespace platf::macos;
  for (const auto *sink : {"", "system", "SYSTEM", "desktop", "ScreenCaptureKit"}) {
    EXPECT_TRUE(uses_native_system_audio(sink));
    EXPECT_TRUE(audio_channels_supported(sink, 2));
    EXPECT_FALSE(audio_channels_supported(sink, 6));
    EXPECT_FALSE(audio_channels_supported(sink, 8));
  }
  EXPECT_TRUE(audio_channels_supported("BlackHole 16ch", 6));
  EXPECT_TRUE(audio_channels_supported("USB Audio", 8));
  EXPECT_FALSE(audio_channels_supported("USB Audio", 3));
}

TEST(MacClickTracker, NearbyClicksIncrementAndReleaseKeepsPressCount) {
  using namespace std::chrono_literals;
  platf::macos::click_tracker_t clicks;
  const auto start = platf::macos::click_tracker_t::clock::now();
  EXPECT_EQ(clicks.update(false, start, 10, 10, 0.5), 1);
  EXPECT_EQ(clicks.update(true, start + 10ms, 10, 10, 0.5), 1);
  EXPECT_EQ(clicks.update(false, start + 100ms, 11, 10, 0.5), 2);
  EXPECT_EQ(clicks.update(true, start + 800ms, 11, 10, 0.5), 2);
  EXPECT_EQ(clicks.update(false, start + 900ms, 11, 10, 0.5), 1);
  EXPECT_EQ(clicks.update(false, start + 1000ms, 11, 10, 0.5), 2);
  EXPECT_EQ(clicks.update(false, start + 1100ms, 11, 10, 0.5), 3);
}

TEST(MacClickTracker, MovementAndUserIntervalResetSequence) {
  using namespace std::chrono_literals;
  platf::macos::click_tracker_t clicks;
  const auto start = platf::macos::click_tracker_t::clock::now();
  EXPECT_EQ(clicks.update(false, start, 0, 0, 0.2), 1);
  EXPECT_EQ(clicks.update(false, start + 100ms, 1000, -600, 0.2), 1);
  EXPECT_EQ(clicks.update(false, start + 400ms, 1000, -600, 0.2), 1);
  EXPECT_EQ(clicks.update(false, start + 700ms, 1000, -600, 0.6), 2);
}

TEST(MacCaptureDisplayBinding, NewCaptureAndRetirementKeepOneAuthoritativeTarget) {
  platf::macos::capture_display_binding_t target;
  EXPECT_EQ(target.snapshot().display, 0u);
  const auto a = target.bind(12, 3840, 2160);
  EXPECT_EQ(target.snapshot().display, 12u);
  const auto b = target.bind(34, 2560, 1440);
  target.clear(a);
  EXPECT_EQ(target.snapshot().display, 34u);
  EXPECT_EQ(target.snapshot().pixel_width, 2560);
  const auto b2 = target.bind(34, 1920, 1080);
  target.clear(b);
  EXPECT_EQ(target.snapshot().display, 34u);
  EXPECT_EQ(target.snapshot().pixel_width, 1920);
  EXPECT_EQ(target.snapshot().pixel_height, 1080);
  target.clear(b2);
  EXPECT_EQ(target.snapshot().display, 0u);
}

#ifdef __APPLE__
TEST(MacCaptureInputTarget, ActualInputResolverFollowsCaptureRatherThanStartupMain) {
  // Published fake IDs return before any CoreGraphics query. No input object is
  // allocated and no input event or display transaction is emitted.
  auto &target = platf::macos::capture_display_binding();
  const auto first = target.bind(98761, 3840, 2160);
  EXPECT_EQ(platf::macos::input_display_target(), 98761u);
  const auto second = target.bind(98762, 1920, 1080);
  target.clear(first);
  EXPECT_EQ(platf::macos::input_display_target(), 98762u);
  target.clear(second);
  EXPECT_EQ(target.snapshot().display, 0u);
}
#endif
