#include <gtest/gtest.h>
#include <src/platform/macos/virtual_display_readiness.h>
#include <vector>

TEST(VirtualDisplayReadiness, RejectsRemovedMirroredAndPlaceholderDisplays) {
  EXPECT_TRUE(skylight_virtual_display_ready(true, true, false, 0, 1920, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(false, false, false, 0, 1, 1));
  EXPECT_FALSE(skylight_virtual_display_ready(false, true, false, 0, 1920, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(true, false, false, 0, 1920, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(true, true, true, 0, 1920, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(true, true, false, 51, 1920, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(true, true, false, 0, 1, 1080));
  EXPECT_FALSE(skylight_virtual_display_ready(true, true, false, 0, 1920, 1));
}

TEST(VirtualDisplayActivation, AlreadyReadyNeverEntersActivationTransaction) {
  int activations = 0;
  const bool ready = skylight_virtual_display_ready(true, true, false, 0, 1440, 900);
  EXPECT_FALSE(skylight_virtual_display_activate_if_needed(ready, [](void *context) {
    ++*static_cast<int *>(context);
  }, &activations));
  EXPECT_EQ(activations, 0);
}

TEST(VirtualDisplayActivation, UnusableDisplaysRetainActivationFallback) {
  for (bool ready : {
         skylight_virtual_display_ready(false, false, false, 0, 1440, 900),
         skylight_virtual_display_ready(true, false, false, 0, 1440, 900),
         skylight_virtual_display_ready(true, true, true, 0, 1440, 900),
         skylight_virtual_display_ready(true, true, false, 52, 1440, 900),
         skylight_virtual_display_ready(true, true, false, 0, 1, 1)}) {
    int activations = 0;
    EXPECT_TRUE(skylight_virtual_display_activate_if_needed(ready, [](void *context) {
      ++*static_cast<int *>(context);
    }, &activations));
    EXPECT_EQ(activations, 1);
  }
}

TEST(VirtualDisplayStartup, ReleasesTimedOutDisplayWithoutSettlingOrStartingCapture) {
  int destroyed = 0;
  int settled = 0;
  std::vector<std::chrono::milliseconds> waits;
  bool ready = platf::macos::prepare_virtual_display(
    []() {
      return 52u;
    },
    [&](auto id, auto timeout) {
      EXPECT_EQ(id, 52u);
      waits.push_back(timeout);
      return false;
    },
    [&]() {
      ++settled;
    },
    [&]() {
      ++destroyed;
    }
  );
  EXPECT_FALSE(ready);
  EXPECT_EQ(destroyed, 1);
  EXPECT_EQ(settled, 0);
  EXPECT_EQ(waits, std::vector {std::chrono::milliseconds(2000)});
}

TEST(VirtualDisplayStartup, DetectsDisplayRemovedDuringSettleAndAllowsCleanRetry) {
  int destroyed = 0;
  bool online = true;
  auto attempt = [&](bool disconnect) {
    return platf::macos::prepare_virtual_display(
      []() {
        return 52u;
      },
      [&](auto, auto) {
        return skylight_virtual_display_ready(online, online, false, 0, online ? 1920 : 1, online ? 1080 : 1);
      },
      [&]() {
        online = !disconnect;
      },
      [&]() {
        ++destroyed;
      }
    );
  };
  EXPECT_FALSE(attempt(true));
  EXPECT_EQ(destroyed, 1);
  online = true;
  EXPECT_TRUE(attempt(false));
  EXPECT_EQ(destroyed, 1);
}

TEST(VirtualDisplayStartup, SuccessRetainsExistingBoundedWaitAndSingleSettle) {
  int settled = 0;
  int destroyed = 0;
  std::vector<std::chrono::milliseconds> waits;
  EXPECT_TRUE(platf::macos::prepare_virtual_display([]() {
    return 52u;
  },
                                                    [&](auto, auto timeout) {
                                                      waits.push_back(timeout);
                                                      return true;
                                                    },
                                                    [&]() {
                                                      ++settled;
                                                    },
                                                    [&]() {
                                                      ++destroyed;
                                                    }));
  EXPECT_EQ(waits, (std::vector {std::chrono::milliseconds(2000), std::chrono::milliseconds(0)}));
  EXPECT_EQ(settled, 1);
  EXPECT_EQ(destroyed, 0);
}

TEST(VirtualDisplayStartup, FailedCreationDoesNotPollSettleOrDestroyAnUnownedDisplay) {
  int side_effects = 0;
  EXPECT_FALSE(platf::macos::prepare_virtual_display([]() {
    return 0u;
  },
                                                     [&](auto, auto) {
                                                       ++side_effects;
                                                       return true;
                                                     },
                                                     [&]() {
                                                       ++side_effects;
                                                     },
                                                     [&]() {
                                                       ++side_effects;
                                                     }));
  EXPECT_EQ(side_effects, 0);
}
