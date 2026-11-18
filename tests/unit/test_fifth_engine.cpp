#include <gtest/gtest.h>
#include <src/adaptive_bitrate.h>
#include <src/streaming_options.h>
#include <src/platform/macos/capture_recovery.h>
#include <src/platform/macos/international_key.h>
#include <src/platform/macos/desktop_scale.h>
#include <src/rtsp.h>
#include <src/stream.h>

using namespace std::chrono_literals;

namespace rtsp_stream { void test_insert_session(const std::shared_ptr<stream::session_t>&); void test_remove_session(const std::shared_ptr<stream::session_t>&); }
namespace stream::session { void test_set_running(session_t&); }

TEST(FifthCaptureRecovery, BudgetSurvivesReplacementAndResetsAfterHealthyWindow) {
  platf::macos::capture_recovery_budget b;
  const auto t=std::chrono::steady_clock::time_point{};
  EXPECT_TRUE(b.request(t)); EXPECT_TRUE(b.request(t+1s)); EXPECT_TRUE(b.request(t+2s));
  EXPECT_FALSE(b.request(t+3s)); EXPECT_FALSE(b.request(t+29s));
  EXPECT_TRUE(b.request(t+30s));
}
TEST(FifthDesktopScale, ExplicitModesOverrideHeuristicAndRejectImpossibleBackingSizes) {
  EXPECT_EQ(skylight_desktop_scale(2560,1440,0),2);
  EXPECT_EQ(skylight_desktop_scale(2560,1440,1),1);
  EXPECT_EQ(skylight_desktop_scale(1920,1080,2),2);
  EXPECT_EQ(skylight_desktop_scale(1921,1080,2),-1);
  EXPECT_EQ(skylight_desktop_scale(1921,1081,0),1);
  EXPECT_EQ(skylight_desktop_scale(1920,1080,3),-1);
  EXPECT_EQ(streaming_options::desktop_scale("auto"),0);
  EXPECT_FALSE(streaming_options::desktop_scale("2junk"));
  EXPECT_FALSE(streaming_options::adaptive_bitrate("true"));
  EXPECT_EQ(streaming_options::adaptive_bitrate("0"),false);
}
TEST(FifthInternationalKey, IsoAndNonNormalizedJisRemainDistinct) {
  EXPECT_EQ(platf::macos::international_key(0xe2,0),0x0a);
  EXPECT_EQ(platf::macos::international_key(0xe2,1),0x5e);
  EXPECT_EQ(platf::macos::international_key(0xe2,2),0x0a);
  EXPECT_EQ(platf::macos::international_key(0xdc,0),-1);
}
static video::frame_fec_status report(unsigned frame,bool loss,unsigned block=0) {
  return {frame,100,20,loss?70u:100u,20,loss?10u:0u,block,2};
}
TEST(FifthAdaptiveBitrate, ModernBigEndianFeedbackRejectsMalformedPackets) {
  std::string bytes(21,'\0');
  bytes[3]=7; bytes[11]=100; bytes[13]=20; bytes[15]=70; bytes[17]=20; bytes[20]=1;
  auto s=video::parse_frame_fec_status(bytes);
  ASSERT_TRUE(s); EXPECT_EQ(s->frame,7); EXPECT_EQ(s->data,100); EXPECT_EQ(s->received_data,70);
  EXPECT_FALSE(video::parse_frame_fec_status(bytes.substr(1)));
  bytes[15]=101; EXPECT_FALSE(video::parse_frame_fec_status(bytes));
  bytes[15]=70; bytes[19]=1; EXPECT_FALSE(video::parse_frame_fec_status(bytes));
}
TEST(FifthAdaptiveBitrate, LossBacksOffWithCadenceFloorAndCeiling) {
  video::adaptive_bitrate_controller c(20000);
  auto t=std::chrono::steady_clock::time_point{};
  EXPECT_TRUE(c.report(report(1,true),t)); EXPECT_EQ(c.target(),15000);
  EXPECT_FALSE(c.report(report(2,true),t+1s)); EXPECT_EQ(c.target(),15000);
  EXPECT_FALSE(c.report(report(1,true),t+2s)); // stale feedback
  EXPECT_TRUE(c.report(report(3,true),t+2s)); EXPECT_EQ(c.target(),11250);
  for(unsigned f=4;f<40;++f) c.report(report(f,true),t+std::chrono::seconds(f*2));
  EXPECT_EQ(c.target(),1000);
}
TEST(FifthAdaptiveBitrate, LaterFecBlockLossIsNotIgnoredAndSilenceDoesNotRaiseRate) {
  video::adaptive_bitrate_controller c(20000);
  auto t=std::chrono::steady_clock::time_point{};
  EXPECT_FALSE(c.report(report(1,false,0),t));
  EXPECT_TRUE(c.report(report(1,true,1),t));
  EXPECT_FALSE(c.report(report(1,true,1),t+2s));
  EXPECT_FALSE(c.report(report(2,false),t+60s)); EXPECT_EQ(c.target(),15000);
  for(unsigned f=3;f<=13;++f) c.report(report(f,false),t+60s+std::chrono::seconds(f-2));
  EXPECT_GT(c.target(),15000); EXPECT_LE(c.target(),20000);
}
TEST(FifthTargetedSession, ExactAuthenticatedIdentityStopsOnlySelectedCurrentSlot) {
  stream::config_t config{};
  rtsp_stream::launch_session_t first{},second{};
  first.id=71; first.authenticated_device_uuid="verified-A"; first.authenticated_device_name="Same name";
  second.id=72; second.authenticated_device_uuid="verified-B"; second.authenticated_device_name="Same name";
  first.gcm_key.resize(16); first.iv.resize(16); second.gcm_key.resize(16); second.iv.resize(16);
  auto a=stream::session::alloc(config,first),b=stream::session::alloc(config,second);
  stream::session::test_set_running(*a); stream::session::test_set_running(*b);
  rtsp_stream::test_insert_session(a); rtsp_stream::test_insert_session(b);
  EXPECT_FALSE(rtsp_stream::terminate_session(70,"verified-A"));
  EXPECT_FALSE(rtsp_stream::terminate_session(71,"verified-B"));
  EXPECT_FALSE(rtsp_stream::terminate_session(71,""));
  EXPECT_TRUE(rtsp_stream::terminate_session(71,"verified-A"));
  EXPECT_FALSE(rtsp_stream::terminate_session(71,"verified-A"));
  EXPECT_EQ(stream::session::state(*a),stream::session::state_e::STOPPING);
  EXPECT_EQ(stream::session::state(*b),stream::session::state_e::RUNNING);
  const auto snap=stream::session::snapshot(*b);
  EXPECT_EQ(snap.session_id,72); EXPECT_EQ(snap.device_uuid,"verified-B"); EXPECT_EQ(snap.device_name,"Same name");
  auto active=rtsp_stream::active_session_snapshot();
  ASSERT_TRUE(active); EXPECT_EQ(active->session_id,72);
  EXPECT_TRUE(rtsp_stream::terminate_session(72,"verified-B"));
  EXPECT_FALSE(rtsp_stream::active_session_snapshot());
  rtsp_stream::test_remove_session(a); rtsp_stream::test_remove_session(b);
}
