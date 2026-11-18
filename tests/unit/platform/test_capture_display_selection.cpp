#include <gtest/gtest.h>
#include <src/platform/macos/capture_display_selection.h>

TEST(CaptureDisplaySelection, AutomaticUsesMainAndExplicitChoiceUsesCurrentId) {
  const std::vector<uint32_t> current {12, 34};
  EXPECT_EQ(platf::macos::select_capture_display(0, 12, "", current), 12u);
  EXPECT_EQ(platf::macos::select_capture_display(0, 12, "34", current), 34u);
}

TEST(CaptureDisplaySelection, RejectsMalformedOverflowAndDisconnectedExplicitIds) {
  const std::vector<uint32_t> current {12, 34};
  for (const auto *invalid : {"Studio Display", "34junk", " 34", "34 ", "+34", "-34", "0", "4294967296", "56"}) {
    EXPECT_FALSE(platf::macos::select_capture_display(0, 12, invalid, current).has_value()) << invalid;
  }
  EXPECT_FALSE(platf::macos::select_capture_display(0, 12, "34", {12}).has_value());
  EXPECT_EQ(platf::macos::select_capture_display(0, 12, "34", {12, 34}), 34u);
}

TEST(CaptureDisplaySelection, SessionVirtualDisplayRetainsPrecedenceOverSavedChoice) {
  for (const auto *saved : {"", "34", "removed", "9999999999999"}) {
    EXPECT_EQ(platf::macos::select_capture_display(99, 12, saved, {12, 34}), 99u);
  }
}
