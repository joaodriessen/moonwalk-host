#include <gtest/gtest.h>
#include <src/audio.h>

namespace {
// The fallback lets the regression expose the former borrowed-pair behavior.
template<class Packet>
auto retain(Packet &packet, const std::shared_ptr<void> &owner, int) -> decltype(packet.channel_owner = owner, void()) {
  packet.channel_owner = owner;
}
template<class Packet>
void retain(Packet &, const std::shared_ptr<void> &, long) {}
}

TEST(AudioPacketLifetime, CurrentPacketKeepsStoppedSessionAliveWithAnotherSessionPresent) {
  auto session = std::make_shared<int>(1), other = std::make_shared<int>(2);
  std::weak_ptr<int> observed = session;
  {
    audio::packet_t packet(session.get(), audio::buffer_t(4));
    retain(packet, session, 0);
    session.reset();
    EXPECT_FALSE(observed.expired());
    EXPECT_EQ(other.use_count(), 1);
    EXPECT_EQ(packet.second.size(), 4u);
  }
  EXPECT_TRUE(observed.expired());
}

TEST(AudioPacketLifetime, QueueClearAndLastCurrentPacketReleaseOnlyTheirOwnSession) {
  auto session = std::make_shared<int>(1), other = std::make_shared<int>(2);
  std::weak_ptr<int> observed = session, other_observed = other;
  std::vector<audio::packet_t> queued;
  for (int i = 0; i < 32; ++i) {
    queued.emplace_back(session.get(), audio::buffer_t(4));
    retain(queued.back(), session, 0);
  }
  auto current = std::move(queued.back());
  queued.pop_back();
  session.reset();
  queued.clear();
  EXPECT_FALSE(observed.expired());
  EXPECT_FALSE(other_observed.expired());
  current = audio::packet_t(nullptr, audio::buffer_t(0));
  EXPECT_TRUE(observed.expired());
  EXPECT_FALSE(other_observed.expired());
}

TEST(AudioPacketLifetime, ConfigurationOwnerDoesNotKeepItsOwnSessionAlive) {
  audio::config_t config {};
  auto session = std::make_shared<int>(1);
  retain(config, session, 0);
  std::weak_ptr<int> observed = session;
  session.reset();
  EXPECT_TRUE(observed.expired());
}
