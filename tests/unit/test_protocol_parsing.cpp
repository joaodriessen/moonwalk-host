#include <gtest/gtest.h>
#include <memory>
#include <src/protocol_parsing.h>
#include <string>

TEST(RtspPlaintextHeaderTest, FindsEveryTwoReadSplitAndPreservesPayload) {
  const std::string header = "ANNOUNCE rtsp://host RTSP/1.0\r\nContent-Length: 4\r\n\r\n";
  const auto message = header + "body";
  for (std::size_t split = 0; split < header.size(); ++split) {
    SCOPED_TRACE(split);
    EXPECT_EQ(rtsp_stream::plaintext_header_end(std::string_view {message}.substr(0, split), 0), std::string_view::npos);
    auto end = rtsp_stream::plaintext_header_end(message, split);
    ASSERT_EQ(end, header.size());
    EXPECT_EQ(std::string_view {message}.substr(end), "body");
  }
}

TEST(RtspPlaintextHeaderTest, HandlesOneByteReadsAndMissingDelimiter) {
  const std::string message = "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n";
  for (std::size_t size = 1; size <= message.size(); ++size) {
    EXPECT_EQ(rtsp_stream::plaintext_header_end(std::string_view {message}.substr(0, size), size - 1), size == message.size() ? size : std::string_view::npos);
  }
  EXPECT_EQ(rtsp_stream::plaintext_header_end({}, 0), std::string_view::npos);
  EXPECT_EQ(rtsp_stream::plaintext_header_end(message, message.size() + 1), std::string_view::npos);
}

TEST(EncryptedControlParsingTest, RejectsEveryTruncatedPacketBeforeFieldAccess) {
  std::string payload(26, '\0');
  payload[0] = 24;  // seq(4) + GCM tag(16) + secondary header(4)
  for (std::size_t size = 0; size < payload.size(); ++size) {
    SCOPED_TRACE(size);
    // Exact allocations let sanitizers detect reads beyond a short packet, including 0..5.
    auto bytes = std::make_unique<char[]>(size);
    std::copy_n(payload.data(), size, bytes.get());
    EXPECT_FALSE(stream::parse_encrypted_control(std::string_view {bytes.get(), size}));
  }
}

TEST(EncryptedControlParsingTest, ValidatesLengthAndDecodesLittleEndianSequence) {
  std::string payload(26, 'x');
  payload[0] = 24;
  payload[1] = 0;
  payload[2] = 0x12;
  payload[3] = 0x34;
  payload[4] = 0x56;
  payload[5] = static_cast<char>(0x89);
  auto parsed = stream::parse_encrypted_control(payload);
  ASSERT_TRUE(parsed);
  EXPECT_EQ(parsed->seq, 0x89563412u);
  EXPECT_EQ(parsed->tagged_cipher, std::string(20, 'x'));
  EXPECT_EQ(parsed->tagged_cipher.data(), payload.data() + 6);

  for (unsigned length : {0u, 4u, 23u, 25u, 65535u}) {
    SCOPED_TRACE(length);
    payload[0] = static_cast<char>(length);
    payload[1] = static_cast<char>(length >> 8);
    EXPECT_FALSE(stream::parse_encrypted_control(payload));
  }
}
