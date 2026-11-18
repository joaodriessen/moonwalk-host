#include <gtest/gtest.h>
#include <src/platform/macos/vd_geometry.h>
#include <src/platform/macos/capture_display_binding.h>

TEST(MacVdGeometry, StrictReplySeparatesModeFailureFromStartupRecovery) {
  vd_geometry_t g{};
  EXPECT_EQ(vd_parse_reply("MODE_ERROR\n", &g), VD_REPLY_MODE_ERROR);
  EXPECT_FALSE(vd_reply_allows_global_cure(VD_REPLY_MODE_ERROR));
  EXPECT_FALSE(vd_reply_allows_global_cure(VD_REPLY_INVALID));
  EXPECT_TRUE(vd_reply_allows_global_cure(vd_parse_reply("0\n", &g)));
  EXPECT_EQ(vd_parse_reply("VDG1 142 -400 30 1440 900 2880 1800 1\n", &g), VD_REPLY_READY);
  EXPECT_EQ(g.x, -400); EXPECT_EQ(g.logical_width, 1440); EXPECT_EQ(g.pixel_width, 2880);
  EXPECT_TRUE(g.is_main);
  EXPECT_TRUE(vd_geometry_can_publish(&g,2880,1800,2));
  EXPECT_TRUE(vd_geometry_matches_request(&g,2880,1800,2));
  EXPECT_TRUE(vd_geometry_matches_request(&g,2880,1800,0));
  EXPECT_FALSE(vd_geometry_matches_request(&g,2880,1800,1));
  EXPECT_FALSE(vd_geometry_matches_request(&g,1920,1080,2));
  EXPECT_FALSE(vd_geometry_matches_request(&g,2881,1800,2));
  EXPECT_EQ(vd_parse_reply("VDG1 142 0 0 1440 900 2880 1800 0\n",&g), VD_REPLY_READY);
  EXPECT_FALSE(vd_geometry_can_publish(&g,2880,1800,2));
  for (const char *bad : {"142\n", "VDG1 142 0 0 1440 900 2880", "VDG1 142 0 0 1440 900 2880 1800\nextra",
      "VDG1 0 0 0 1440 900 2880 1800\n", "VDG1 142 0 0 1440 900 9000 1800\n",
      "VDG1 142 999999999999999999999 0 1440 900 2880 1800\n", "VDG1 142 0 0 3000 900 2880 1800\n",
      "VDG1 142 0 0 1440 900 2880 1800 2\n", "VDG1 \t142 0 0 1440 900 2880 1800 1\n",
      "VDG1 142 0 0 1440 900 2880 1800 1\nextra"}) {
    EXPECT_EQ(vd_parse_reply(bad, &g), VD_REPLY_INVALID) << bad;
    EXPECT_EQ(g.display,0u); EXPECT_EQ(g.pixel_width,0);
  }
}

TEST(MacVdGeometry, CurrentModeMustAlsoMeetFrameRate) {
  EXPECT_FALSE(vd_mode_rate_matches(60,30));
  EXPECT_TRUE(vd_mode_rate_matches(60,60));
  EXPECT_TRUE(vd_mode_rate_matches(60,59.94));
  EXPECT_TRUE(vd_mode_rate_matches(60,0));
  EXPECT_FALSE(vd_mode_rate_matches(60,60.5));
}

TEST(MacVdGeometry, FailedFlipCannotBeRescuedByUnjournaledLaterMainSnapshot) {
  EXPECT_FALSE(vd_flip_allows_publish(false,false,true));
  EXPECT_FALSE(vd_flip_allows_publish(false,true,false));
  EXPECT_TRUE(vd_flip_allows_publish(false,true,true));
  // Already-main/headless has no physical movement journal to create.
  EXPECT_TRUE(vd_flip_allows_publish(true,false,true));
}

TEST(MacVdGeometry, CapturedLogicalRectOverridesProxyBoundsAndClampsEdges) {
  platf::macos::capture_display_binding_t binding;
  vd_geometry_t geometry{142, 9, -1440, 100, 1440, 900, 2880, 1800};
  auto first = binding.bind(142, 2880, 1800, &geometry);
  auto s = binding.snapshot();
  ASSERT_TRUE(s.has_geometry());
  auto center = s.logical_point(1440, 900);
  EXPECT_EQ(center.first, -720); EXPECT_EQ(center.second, 550);
  auto edge = s.logical_point(99999, -1);
  EXPECT_EQ(edge.first, -1); EXPECT_EQ(edge.second, 100);
  auto next = binding.bind(143, 1920, 1080);
  binding.clear(first);
  EXPECT_EQ(binding.snapshot().display, 143u); EXPECT_FALSE(binding.snapshot().has_geometry());
  binding.clear(next); EXPECT_EQ(binding.snapshot().display, 0u);
  binding.bind(142,0,1800,&geometry); EXPECT_FALSE(binding.snapshot().has_geometry());
  binding.bind(142,1920,1080,&geometry); EXPECT_FALSE(binding.snapshot().has_geometry());
  binding.bind(143,2880,1800,&geometry); EXPECT_FALSE(binding.snapshot().has_geometry());
  geometry.generation=0;
  binding.bind(142,2880,1800,&geometry); EXPECT_FALSE(binding.snapshot().has_geometry());
}
