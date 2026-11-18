/**
 * @file tests/unit/test_mouse.cpp
 * @brief Test src/input.*.
 */
#include "../tests_common.h"

#include <src/input.h>

#ifdef __APPLE__
  #include <CoreGraphics/CoreGraphics.h>

  #include <src/platform/macos/virtual_display.h>

namespace {
  struct macos_display_geometry_t {
    CGFloat scaling;
    CGPoint origin;
    CGSize size;
  };

  macos_display_geometry_t active_macos_display_geometry() {
    const auto virtual_display = virtual_display_get_id();
    const auto display = virtual_display ? static_cast<CGDirectDisplayID>(virtual_display) : CGMainDisplayID();
    const auto bounds = CGDisplayBounds(display);
    CGFloat scaling = 1.0;
    if (const auto mode = CGDisplayCopyDisplayMode(display)) {
      const auto pixel_width = static_cast<CGFloat>(CGDisplayModeGetPixelWidth(mode));
      if (pixel_width > 0.0) {
        scaling = bounds.size.width / pixel_width;
      }
      CFRelease(mode);
    }
    return {scaling, bounds.origin, bounds.size};
  }
}  // namespace
#endif

struct MouseHIDTest: PlatformTestSuite, testing::WithParamInterface<util::point_t> {
#ifdef __APPLE__
  CGPoint original_cursor {};
  bool restore_cursor = false;
#endif
  void SetUp() override {
#ifdef __APPLE__
    const auto event = CGEventCreate(nullptr);
    ASSERT_NE(event, nullptr);
    original_cursor = CGEventGetLocation(event);
    CFRelease(event);
    restore_cursor = true;
    const auto geometry = active_macos_display_geometry();
    // Relative movement must start away from edges: an existing cursor near the
    // bottom otherwise clamps a valid delta and fails depending on prior use.
    ASSERT_EQ(CGWarpMouseCursorPosition(CGPointMake(
                geometry.origin.x + geometry.size.width / 2,
                geometry.origin.y + geometry.size.height / 2)), kCGErrorSuccess);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
#elif defined(_WIN32)
    // TODO: Windows tests are failing, `get_mouse_loc` seems broken and `platf::abs_mouse` too
    //       the alternative `platf::abs_mouse` method seem to work better during tests,
    //       but I'm not sure about real work
    GTEST_SKIP() << "TODO Windows";
#elif defined(__linux__) || defined(__FreeBSD__)
    // TODO: Inputtino waiting https://github.com/games-on-whales/inputtino/issues/6 is resolved.
    GTEST_SKIP() << "TODO Inputtino";
#endif
  }

  void TearDown() override {
#ifdef __APPLE__
    if (restore_cursor) {
      CGWarpMouseCursorPosition(original_cursor);
    }
#endif
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
};

INSTANTIATE_TEST_SUITE_P(
  MouseInputs,
  MouseHIDTest,
  testing::Values(
    util::point_t {40, 40},
    util::point_t {70, 150}
  )
);

// todo: add tests for hitting screen edges

TEST_P(MouseHIDTest, MoveInputTest) {
  util::point_t mouse_delta = GetParam();

  BOOST_LOG(tests) << "MoveInputTest:: got param: " << mouse_delta;
  platf::input_t input = platf::input();
  BOOST_LOG(tests) << "MoveInputTest:: init input";

  BOOST_LOG(tests) << "MoveInputTest:: get current mouse loc";
  auto old_loc = platf::get_mouse_loc(input);
  BOOST_LOG(tests) << "MoveInputTest:: got current mouse loc: " << old_loc;

  BOOST_LOG(tests) << "MoveInputTest:: move: " << mouse_delta;
  platf::move_mouse(input, mouse_delta.x, mouse_delta.y);
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  BOOST_LOG(tests) << "MoveInputTest:: moved: " << mouse_delta;

  BOOST_LOG(tests) << "MoveInputTest:: get updated mouse loc";
  auto new_loc = platf::get_mouse_loc(input);
  BOOST_LOG(tests) << "MoveInputTest:: got updated mouse loc: " << new_loc;

  bool has_input_moved = old_loc.x != new_loc.x && old_loc.y != new_loc.y;

  if (!has_input_moved) {
    BOOST_LOG(tests) << "MoveInputTest:: haven't moved";
  } else {
    BOOST_LOG(tests) << "MoveInputTest:: moved";
  }

  EXPECT_TRUE(has_input_moved);

  // Verify we moved as much as we requested
#ifdef __APPLE__
  const auto geometry = active_macos_display_geometry();
  // CoreGraphics reports cursor locations in display points and can round the
  // sampled start/end positions at fractional backing scales. One point still
  // catches a wrong scale while avoiding exact-float flakes on a live display.
  EXPECT_NEAR(new_loc.x - old_loc.x, mouse_delta.x * geometry.scaling, 1.0);
  EXPECT_NEAR(new_loc.y - old_loc.y, mouse_delta.y * geometry.scaling, 1.0);
#else
  EXPECT_EQ(new_loc.x - old_loc.x, mouse_delta.x);
  EXPECT_EQ(new_loc.y - old_loc.y, mouse_delta.y);
#endif
}

TEST_P(MouseHIDTest, AbsMoveInputTest) {
  util::point_t mouse_pos = GetParam();
  BOOST_LOG(tests) << "AbsMoveInputTest:: got param: " << mouse_pos;

  platf::input_t input = platf::input();
  BOOST_LOG(tests) << "AbsMoveInputTest:: init input";

  BOOST_LOG(tests) << "AbsMoveInputTest:: get current mouse loc";
  auto old_loc = platf::get_mouse_loc(input);
  BOOST_LOG(tests) << "AbsMoveInputTest:: got current mouse loc: " << old_loc;

#ifdef _WIN32
  platf::touch_port_t abs_port {
    0,
    0,
    65535,
    65535
  };
#elif defined(__linux__) || defined(__FreeBSD__)
  platf::touch_port_t abs_port {
    0,
    0,
    19200,
    12000
  };
#else
  platf::touch_port_t abs_port {};
#endif
  BOOST_LOG(tests) << "AbsMoveInputTest:: move: " << mouse_pos;
  platf::abs_mouse(input, abs_port, mouse_pos.x, mouse_pos.y);
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  BOOST_LOG(tests) << "AbsMoveInputTest:: moved: " << mouse_pos;

  BOOST_LOG(tests) << "AbsMoveInputTest:: get updated mouse loc";
  auto new_loc = platf::get_mouse_loc(input);
  BOOST_LOG(tests) << "AbsMoveInputTest:: got updated mouse loc: " << new_loc;

  bool has_input_moved = old_loc.x != new_loc.x || old_loc.y != new_loc.y;

  if (!has_input_moved) {
    BOOST_LOG(tests) << "AbsMoveInputTest:: haven't moved";
  } else {
    BOOST_LOG(tests) << "AbsMoveInputTest:: moved";
  }

  EXPECT_TRUE(has_input_moved);

  // Verify we moved to the absolute coordinate
#ifdef __APPLE__
  const auto geometry = active_macos_display_geometry();
  EXPECT_EQ(new_loc.x, mouse_pos.x * geometry.scaling + geometry.origin.x);
  EXPECT_EQ(new_loc.y, mouse_pos.y * geometry.scaling + geometry.origin.y);
#else
  EXPECT_EQ(new_loc.x, mouse_pos.x);
  EXPECT_EQ(new_loc.y, mouse_pos.y);
#endif
}
