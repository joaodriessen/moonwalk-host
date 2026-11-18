/**
 * @file tests/unit/test_stream.cpp
 * @brief Test src/stream.*
 */

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace stream {
  std::vector<uint8_t> concat_and_insert(uint64_t insert_size, uint64_t slice_size, const std::string_view &data1, const std::string_view &data2);
}

#include "../tests_common.h"

TEST(ConcatAndInsertTests, ConcatNoInsertionTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(0, 2, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {'a', 'b', 'c', 'd', 'e'};
  ASSERT_EQ(res, expected);
}

TEST(ConcatAndInsertTests, ConcatLargeStrideTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(1, sizeof(b1) + sizeof(b2) + 1, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {0, 'a', 'b', 'c', 'd', 'e'};
  ASSERT_EQ(res, expected);
}

TEST(ConcatAndInsertTests, ConcatSmallStrideTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(1, 1, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {0, 'a', 0, 'b', 0, 'c', 0, 'd', 0, 'e'};
  ASSERT_EQ(res, expected);
}

// ---------------------------------------------------------------------
// Control-channel runt-packet bounds (U1-U4, wave-B deep-hunt fix) -- DOCUMENTED GAP, not
// unit-testable in this pass.
//
// The fixed handlers are lambdas registered inside controlBroadcastThread(control_server_t*)
// (src/stream.cpp:928) via server->map(...), and a fifth guard lives inline in the ENet event
// loop around stream.cpp:589. All five take a real session_t* (which itself needs a live cipher,
// IV state, video/audio event queues, etc.) and/or a live ENet peer/packet -- there is no builder
// for either in this codebase or test suite today, and session_t itself isn't exposed via a
// header that a test could construct standalone. Extracting the bounds checks into pure,
// independently-callable helpers would be a src/ change, out of scope for this test-only pass.
//
// Exact fixed scenarios that need an integration harness (a real control_server_t + session_t +
// either a loopback ENet peer or a way to invoke control_server_t::call() directly) to cover:
//   - stream.cpp:589 -- generic ENet control-channel dispatch: a packet with
//     dataLength < sizeof(uint16_t) (i.e. 0 or 1 byte) must be dropped ("Control: Runt packet")
//     instead of `*(uint16_t*)packet->data` reading past the packet buffer.
//   - stream.cpp:942 (IDX_LOSS_STATS) -- a payload shorter than 4*sizeof(int32_t) = 16 bytes must
//     be dropped instead of `(int32_t*)payload.data()` indexing stats[0..3] out of bounds.
//   - stream.cpp:969 (IDX_INVALIDATE_REF_FRAMES) -- a payload shorter than 2*sizeof(int64_t) = 16
//     bytes must be dropped instead of reading frames[0]/frames[1] out of bounds.
//   - stream.cpp:989-999 (IDX_INPUT_DATA) -- a payload shorter than sizeof(int32_t) = 4 bytes (a
//     "6-byte IDX_INPUT_DATA packet" would actually pass this specific length check but MUST still
//     be caught by the immediately-following tagged_cipher_length bounds check at stream.cpp:996,
//     since a spoofed/garbage big-endian length prefix in those 4 bytes could otherwise claim a
//     cipher length that reads past the real 2-byte remainder) must not terminate the daemon by
//     constructing an out-of-bounds string_view.
// Encrypted-header bounds now have a pure production parser and direct regressions in
// test_protocol_parsing.cpp, including exact-size allocations for every truncated header.
// ---------------------------------------------------------------------
