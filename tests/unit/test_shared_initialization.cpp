#include <gtest/gtest.h>
#include <stdexcept>
#include <src/thread_safe.h>

namespace {
  // Inert exclusive-resource stand-in: acquiring it twice fails, as an already-bound
  // broadcast socket does. No socket, device, thread or platform initialization.
  struct lease_state {
    bool held = false;
    bool fail = true;
    int destructions = 0;
    int successful_cleanup = 0;
  };
  struct lease {
    lease_state *state = nullptr;
    ~lease() {
      if (state) { state->held = false; ++state->destructions; }
    }
  };
}

TEST(SharedInitialization, FailedInitializerReleasesExclusiveResourceAndAllowsRetry) {
  static lease_state state;
  static auto owner = safe::make_shared<lease>([](lease &value) {
    if (state.held) return -1;
    state.held = true; value.state = &state;
    return state.fail ? -1 : 0;
  }, [](lease &) { ++state.successful_cleanup; });
  state = {};
  EXPECT_FALSE(owner.ref());
  EXPECT_FALSE(state.held);
  EXPECT_EQ(state.destructions, 1);
  EXPECT_EQ(state.successful_cleanup, 0); // success-only shutdown must not join unstarted threads
  state.fail = false;
  {
    auto retry = owner.ref();
    ASSERT_TRUE(retry);
    auto second = retry;
    EXPECT_TRUE(state.held);
  }
  EXPECT_FALSE(state.held);
  EXPECT_EQ(state.destructions, 2);
  EXPECT_EQ(state.successful_cleanup, 1);
}

TEST(SharedInitialization, ThrowingInitializerAlsoReleasesPartialResource) {
  static lease_state state;
  static auto owner = safe::make_shared<lease>([](lease &value) -> int {
    if (state.held) return -1;
    state.held = true; value.state = &state;
    if (state.fail) throw std::runtime_error("inert initialization failure");
    return 0;
  }, [](lease &) { ++state.successful_cleanup; });
  state = {};
  EXPECT_THROW((void)owner.ref(), std::runtime_error);
  EXPECT_FALSE(state.held);
  EXPECT_EQ(state.destructions, 1);
  EXPECT_EQ(state.successful_cleanup, 0);
  state.fail = false;
  { auto retry = owner.ref(); ASSERT_TRUE(retry); }
  EXPECT_EQ(state.destructions, 2);
  EXPECT_EQ(state.successful_cleanup, 1);
}
