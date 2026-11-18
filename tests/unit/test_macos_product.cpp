#ifdef __APPLE__
#include <gtest/gtest.h>
#include <src/platform/macos/audio_source_probe.h>
#include <src/platform/macos/xpc_control.h>
#include <src/listener_readiness.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

namespace {
  struct ProbeMicrophone: platf::mic_t {
    std::atomic_bool &cancel;
    int reads = 0;
    bool error = false;
    ProbeMicrophone(std::atomic_bool &cancel): cancel(cancel) {}
    platf::capture_e sample(std::vector<float> &samples) override {
      ++reads;
      if (error) { return platf::capture_e::reinit; }
      std::fill(samples.begin(), samples.end(), 0.0f);
      samples[0] = -0.5f;
      samples[1] = std::numeric_limits<float>::quiet_NaN();
      cancel = true;
      return platf::capture_e::ok;
    }
  };
}

TEST(MacosSoundProbe, UsesActualMicrophoneContractAndOnlyReportsAggregateActivity) {
  std::atomic_bool cancel {false};
  ProbeMicrophone microphone(cancel);
  const auto result = platf::macos::probe_audio_source(microphone, cancel);
  EXPECT_EQ(microphone.reads, 1);
  EXPECT_EQ(result.samples, 960u);
  EXPECT_FLOAT_EQ(result.peak, 0.5f);
  EXPECT_TRUE(result.cancelled);
  EXPECT_FALSE(result.failed);
}

TEST(MacosSoundProbe, CancelAndDeadlineDoNotStartCaptureReadsAndFailureIsDistinctFromSilence) {
  std::atomic_bool cancel {true};
  ProbeMicrophone microphone(cancel);
  EXPECT_TRUE(platf::macos::probe_audio_source(microphone, cancel).cancelled);
  EXPECT_EQ(microphone.reads, 0);
  cancel = false;
  EXPECT_EQ(platf::macos::probe_audio_source(microphone, cancel, std::chrono::milliseconds(0)).samples, 0u);
  EXPECT_EQ(microphone.reads, 0);
  microphone.error = true;
  const auto result = platf::macos::probe_audio_source(microphone, cancel);
  EXPECT_TRUE(result.failed);
  EXPECT_EQ(result.samples, 0u);
}

TEST(MacosConnectionHandoff, ChecksARealLocalListenerWithoutClaimingRemoteReachability) {
  const int server = socket(AF_INET, SOCK_STREAM, 0);
  ASSERT_GE(server, 0);
  sockaddr_in address {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ASSERT_EQ(bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)), 0);
  ASSERT_EQ(listen(server, 2), 0);
  socklen_t length = sizeof(address);
  ASSERT_EQ(getsockname(server, reinterpret_cast<sockaddr *>(&address), &length), 0);
  const auto port = ntohs(address.sin_port);
  net::set_listener_ready(net::listener_kind::http, false);
  EXPECT_FALSE(platf::macos::owned_listener_ready_for_tests(port)); // another service is insufficient
  net::set_listener_ready(net::listener_kind::http, true);
  EXPECT_TRUE(platf::macos::owned_listener_ready_for_tests(port));
  EXPECT_TRUE(platf::macos::local_listener_ready_for_tests(port));
  close(server);
  net::set_listener_ready(net::listener_kind::http, false);
  EXPECT_FALSE(platf::macos::local_listener_ready_for_tests(port));
}

TEST(MacosConnectionHandoff, ChecksAnIPv6OnlyLocalListener) {
  const int server = socket(AF_INET6, SOCK_STREAM, 0);
  ASSERT_GE(server, 0);
  const int only = 1;
  ASSERT_EQ(setsockopt(server, IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only)), 0);
  sockaddr_in6 address {};
  address.sin6_family = AF_INET6; address.sin6_addr = in6addr_loopback;
  ASSERT_EQ(bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)), 0);
  ASSERT_EQ(listen(server, 2), 0);
  socklen_t length = sizeof(address);
  ASSERT_EQ(getsockname(server, reinterpret_cast<sockaddr *>(&address), &length), 0);
  EXPECT_TRUE(platf::macos::local_listener_ready_for_tests(ntohs(address.sin6_port)));
  close(server);
}
#endif
