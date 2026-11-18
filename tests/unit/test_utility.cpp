/**
 * @file tests/unit/test_utility.cpp
 * @brief Test src/utility.h -- regression coverage for the from_hex<T>() stack-smash fix (U9).
 *
 * util::from_hex<T>() converts a hex string into a fixed-size POD of type T by writing into a
 * `std::uint8_t buf[sizeof(T)]` stack array. Before the fix, `buf_size` (the number of hex-digit
 * pairs found in the input) was subtracted from `sizeof(T)` in UNSIGNED arithmetic with no upper
 * clamp: `auto padding = sizeof(T) - buf_size;`. An over-long hex string (more than 2*sizeof(T)
 * convertible hex digits) made buf_size > sizeof(T), so the subtraction wrapped around to a huge
 * value and `std::fill_n(buf + buf_size, padding, 0)` / the following `for_each_n(buf, buf_size,
 * ...)` walked far past the end of the fixed-size stack buffer -- a classic stack-smash primitive
 * from attacker/malformed-input-controlled hex strings (e.g. pairing/crypto hex fields).
 *
 * The fix clamps buf_size to sizeof(T) before computing padding, so any hex string longer than
 * the destination truncates to the least-significant sizeof(T) bytes instead of overflowing.
 */
#include "../tests_common.h"

#include <cstdint>
#include <cstring>

#include <src/utility.h>

// ---------------------------------------------------------------------
// from_hex<T>() -- valid-length input is unchanged by the clamp.
// ---------------------------------------------------------------------

TEST(FromHexTest, ExactLengthUint32ParsesCorrectly) {
  // "DEADBEEF" is exactly 2*sizeof(uint32_t) = 8 hex chars.
  auto value = util::from_hex<std::uint32_t>("DEADBEEF");

  std::uint8_t expected_bytes[4] = {0xEF, 0xBE, 0xAD, 0xDE};  // native little-endian layout
  std::uint32_t expected;
  std::memcpy(&expected, expected_bytes, sizeof(expected));

  EXPECT_EQ(value, expected);
}

TEST(FromHexTest, ExactLengthUint16ParsesCorrectly) {
  auto value = util::from_hex<std::uint16_t>("1234");
  EXPECT_EQ(value, static_cast<std::uint16_t>(0x1234));
}

TEST(FromHexTest, ShortInputIsZeroPadded) {
  // Fewer than 2*sizeof(T) digits: high-order bytes should be zero-padded, not garbage.
  auto value = util::from_hex<std::uint32_t>("AB");
  EXPECT_EQ(value, static_cast<std::uint32_t>(0xAB));
}

// ---------------------------------------------------------------------
// from_hex<T>() -- the U9 regression: over-long input must not overflow the fixed-size
// stack buffer, and must truncate to the correctly-defined low-order bytes instead.
// ---------------------------------------------------------------------

TEST(FromHexTest, OverLongInputForIntDoesNotOverflowAndTruncatesLowOrderBytes) {
  // sizeof(int) == 4 on every platform this project targets, so 2*sizeof(int) == 8 hex chars is
  // the "exact" length; this string supplies 12 (FFFFFFFFFFFF), 4 more than fits.
  // buf_size (pre-clamp) would be 6, sizeof(int) - 6 wraps to a huge value in unsigned math --
  // that's the exact stack-smash primitive this test protects against.
  auto value = util::from_hex<int>("FFFFFFFFFFFF");

  // Parsing walks from the END of the string backwards filling the least-significant bytes
  // first, so the low-order sizeof(int) bytes of "FFFFFFFFFFFF" (which is uniformly 'F') are
  // just as many 0xFF bytes as fit -- i.e. truncation to -1 for a 4-byte int, not a crash and
  // not the untruncated 6-byte value.
  EXPECT_EQ(value, -1);
}

TEST(FromHexTest, OverLongInputForUint16TruncatesToLowOrderBytes) {
  // sizeof(uint16_t) == 2, so this 8-char string is 4x too long. Low-order 2 bytes of
  // "DEADBEEF" are "BEEF".
  auto value = util::from_hex<std::uint16_t>("DEADBEEF");
  EXPECT_EQ(value, static_cast<std::uint16_t>(0xBEEF));
}

TEST(FromHexTest, MassivelyOverLongInputStillTruncatesCorrectlyNoCrash) {
  // Far beyond any plausible sizeof(T): 64 hex chars ('A' repeated) into a 4-byte destination.
  // This is the shape a malformed/attacker-controlled hex field (e.g. a pairing or crypto hex
  // parameter) could take; the fixed clamp must hold regardless of how long the string is.
  std::string huge_hex(64, 'A');
  auto value = util::from_hex<std::uint32_t>(huge_hex);
  EXPECT_EQ(value, static_cast<std::uint32_t>(0xAAAAAAAA));
}

TEST(FromHexTest, OverLongInputWithRevFlagStillBounded) {
  // The `rev` path reverses the already-clamped buffer -- exercise it too since it's a separate
  // code path (std::reverse over the same fixed buf[sizeof(T)]).
  auto value = util::from_hex<std::uint32_t>("112233445566778899", true);
  // Non-crash + deterministic result is what matters here; pin the actual value so any future
  // change to the truncation semantics is caught.
  auto expected_forward = util::from_hex<std::uint32_t>("112233445566778899", false);
  std::uint8_t bytes[4];
  std::memcpy(bytes, &expected_forward, sizeof(bytes));
  std::reverse(std::begin(bytes), std::end(bytes));
  std::uint32_t expected_reversed;
  std::memcpy(&expected_reversed, bytes, sizeof(expected_reversed));
  EXPECT_EQ(value, expected_reversed);
}

// ---------------------------------------------------------------------
// from_hex_vec() -- dynamically-sized (std::string, not a fixed stack buffer), so an over-long
// input just produces a longer output rather than needing a clamp. Documented here for
// completeness per the U9 test plan: confirms the *other* hex parser in the same header behaves
// sanely (no truncation, no crash) and is not itself a smash vector.
// ---------------------------------------------------------------------

TEST(FromHexVecTest, ValidLengthRoundTrips) {
  auto bytes = util::from_hex_vec("DEADBEEF");
  ASSERT_EQ(bytes.size(), 4u);
  EXPECT_EQ(static_cast<std::uint8_t>(bytes[0]), 0xEF);
  EXPECT_EQ(static_cast<std::uint8_t>(bytes[1]), 0xBE);
  EXPECT_EQ(static_cast<std::uint8_t>(bytes[2]), 0xAD);
  EXPECT_EQ(static_cast<std::uint8_t>(bytes[3]), 0xDE);
}

TEST(FromHexVecTest, OverLongInputProducesFullLengthNoCrash) {
  // Unlike from_hex<T>(), from_hex_vec() sizes its buffer (a std::string) to the ACTUAL digit
  // count, so there is no fixed-size destination to overflow -- 64 hex chars simply produce a
  // 32-byte result.
  std::string huge_hex(64, 'A');
  auto bytes = util::from_hex_vec(huge_hex);
  ASSERT_EQ(bytes.size(), 32u);
  for (unsigned char c : bytes) {
    EXPECT_EQ(c, 0xAA);
  }
}
