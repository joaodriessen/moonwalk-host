#include <gtest/gtest.h>
#include <src/video.h>
#include <type_traits>

namespace stream {
  std::vector<uint8_t> replace(const std::string_view &, const std::string_view &, const std::string_view &);
}
namespace {
  using replacements_t = std::vector<video::packet_raw_t::replace_t>;
  // Keep the regression runnable against the former borrowed-pointer API too:
  // ASan then diagnoses the actual queued-packet use-after-free.
  template<class Pointer>
  void attach_encoder_set(Pointer &packet, const std::shared_ptr<replacements_t> &encoder) {
    if constexpr (std::is_pointer_v<Pointer>) packet = encoder.get();
    else packet = encoder;
  }
}

TEST(PacketReplacements, QueuedPacketOutlivesEncoderAndItsNalBuffers) {
  video::packet_raw_generic queued({}, 1, true);
  const std::string expected_old(128, '\0'), expected_new(192, '\xff');
  {
    std::string old_nal = expected_old, new_nal = expected_new;
    auto encoder = std::make_shared<replacements_t>();
    encoder->emplace_back(old_nal, new_nal);
    attach_encoder_set(queued.replacements, encoder);
  }
  ASSERT_EQ(queued.replacements->size(), 1u);
  EXPECT_EQ(queued.replacements->at(0).old, expected_old);
  EXPECT_EQ(queued.replacements->at(0)._new, expected_new);
}

TEST(PacketReplacements, ReplacementBytesDoNotAliasMutableSourceBuffers) {
  auto encoder = std::make_shared<replacements_t>();
  std::string old_nal("\0\0\1sps\0old", 10), new_nal("\0\0\1sps\0new-long", 15);
  const auto expected_old = old_nal, expected_new = new_nal;
  encoder->emplace_back(old_nal, new_nal);
  video::packet_raw_generic queued({}, 2, true);
  attach_encoder_set(queued.replacements, encoder);
  std::fill(old_nal.begin(), old_nal.end(), 'x');
  std::fill(new_nal.begin(), new_nal.end(), 'y');
  EXPECT_EQ(queued.replacements->at(0).old, expected_old);
  EXPECT_EQ(queued.replacements->at(0)._new, expected_new);
}

TEST(PacketReplacements, PacketsShareOneSetInsteadOfCopyingPerFrame) {
  auto encoder = std::make_shared<replacements_t>();
  encoder->emplace_back("SPS", "new SPS");
  video::packet_raw_generic first({}, 1, true), second({}, 2, true);
  attach_encoder_set(first.replacements, encoder);attach_encoder_set(second.replacements, encoder);
  EXPECT_EQ(first.replacements, second.replacements);
}

TEST(PacketReplacements, MultipleBinaryReplacementsCanResizeTheirPriorOutput) {
  std::string payload("a\0SPS\0mid\0VPS\0z", 15);
  const std::string old_sps("\0SPS\0", 5), new_sps("\0newSPS\0", 8);
  const std::string old_vps("\0VPS\0", 5), new_vps("\0V\0", 3);
  std::vector<uint8_t> output;
  std::string_view view(payload);
  for (const auto &pair : {std::pair(old_sps, new_sps), std::pair(old_vps, new_vps)}) {
    output = stream::replace(view, pair.first, pair.second);
    view = {reinterpret_cast<const char *>(output.data()), output.size()};
  }
  EXPECT_EQ(view, std::string("a\0newSPS\0mid\0V\0z", 16));
}

TEST(PacketReplacements, SessionConfigOwnerIsWeakAndCannotRetainItself) {
  struct owner_t { video::config_t config {}; };
  auto owner = std::make_shared<owner_t>();
  std::weak_ptr<owner_t> observed = owner;
  owner->config.channel_owner = owner;
  owner.reset();
  EXPECT_TRUE(observed.expired());
}

TEST(PacketReplacements, QueuedPacketsRetainRawSessionUntilLastPacketIsDropped) {
  struct owner_t { int marker = 42; };
  auto owner = std::make_shared<owner_t>();
  std::weak_ptr<owner_t> observed = owner;
  video::config_t config {};
  config.channel_owner = owner;
  auto first = std::make_unique<video::packet_raw_generic>(std::vector<uint8_t>{}, 1, true);
  auto second = std::make_unique<video::packet_raw_generic>(std::vector<uint8_t>{}, 2, false);
  for (auto packet : {first.get(), second.get()}) {
    packet->channel_data = owner.get();
    packet->channel_owner = config.channel_owner.lock();
  }
  owner.reset();
  ASSERT_FALSE(observed.expired());
  EXPECT_EQ(static_cast<owner_t *>(first->channel_data)->marker, 42);
  first.reset();
  ASSERT_FALSE(observed.expired());
  EXPECT_EQ(static_cast<owner_t *>(second->channel_data)->marker, 42);
  second.reset();
  EXPECT_TRUE(observed.expired());
}
