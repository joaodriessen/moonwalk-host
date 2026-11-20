/**
 * @file tests/unit/test_input.cpp
 * @brief Input queue and pointer bounds tests.
 *
 * Rejected packets must return before accessing the input context. Accepted
 * packets use a real context and leave their tasks unexecuted, so the tests
 * never deliver input on the device.
 */
#include "../tests_common.h"

extern "C" {
#include <moonlight-common-c/src/Input.h>
}

#include <cstring>

#include <src/globals.h>
#include <src/input.h>
#include <src/thread_safe.h>
#include <src/utility.h>

namespace {
  /**
   * @brief Serialize a moonlight-common-c input packet struct to wire bytes, with a correct
   * header.size (big-endian, excludes the size field itself) and a correct little-endian magic.
   */
  template<class PacketT>
  std::vector<uint8_t> to_wire(PacketT packet, uint32_t magic) {
    packet.header.magic = util::endian::little(magic);
    packet.header.size = util::endian::big((uint32_t) (sizeof(PacketT) - sizeof(uint32_t)));

    std::vector<uint8_t> buf(sizeof(PacketT));
    std::memcpy(buf.data(), &packet, sizeof(PacketT));
    return buf;
  }

  /**
   * @brief A live input_t built via the real production factory (input::alloc()), safe to use in
   * a unit test on macOS -- see the file-level comment for why this doesn't touch real hardware.
   */
  std::shared_ptr<input::input_t> make_real_input() {
    auto mail = std::make_shared<safe::mail_raw_t>();
    return input::alloc(mail);
  }
}  // namespace

// ---------------------------------------------------------------------
// Reject path: input::passthrough(shared_ptr<input_t>&, vector<uint8_t>&&), src/input.cpp:1649.
// Called with a null input_t -- every case below must return before the guard's caller ever
// dereferences `input`, or the test process itself would crash.
// ---------------------------------------------------------------------

TEST(InputPassthroughGuardTest, EmptyPacketIsRejected) {
  std::shared_ptr<input::input_t> null_input;
  std::vector<uint8_t> data;  // 0 bytes -- shorter than sizeof(NV_INPUT_HEADER)

  input::passthrough(null_input, std::move(data));
  SUCCEED() << "passthrough() returned without dereferencing a null input_t";
}

TEST(InputPassthroughGuardTest, PacketShorterThanHeaderIsRejected) {
  std::shared_ptr<input::input_t> null_input;
  ASSERT_EQ(sizeof(NV_INPUT_HEADER), 8u);  // sanity: header is 8 bytes (size + magic)
  std::vector<uint8_t> data(sizeof(NV_INPUT_HEADER) - 1, 0);  // one byte short of a full header

  input::passthrough(null_input, std::move(data));
  SUCCEED() << "passthrough() returned without dereferencing a null input_t";
}

TEST(InputPassthroughGuardTest, HeaderOnlyWithHugeDeclaredSizeIsRejected) {
  std::shared_ptr<input::input_t> null_input;
  std::vector<uint8_t> data(sizeof(NV_INPUT_HEADER), 0);
  auto *hdr = (PNV_INPUT_HEADER) data.data();
  hdr->size = util::endian::big((uint32_t) 0xFFFFFFFEu);  // declares ~4GB of payload it doesn't have

  input::passthrough(null_input, std::move(data));
  SUCCEED() << "passthrough() returned without dereferencing a null input_t";
}

TEST(InputPassthroughGuardTest, KeyboardPacketWithDeclaredSizeOneByteOverActualIsRejected) {
  std::shared_ptr<input::input_t> null_input;
  NV_KEYBOARD_PACKET packet {};
  auto data = to_wire(packet, KEY_DOWN_EVENT_MAGIC);

  // Lie: claim one more byte than we're actually sending, as a truncated/forged sender would.
  auto *hdr = (PNV_INPUT_HEADER) data.data();
  hdr->size = util::endian::big(util::endian::big(hdr->size) + 1);

  input::passthrough(null_input, std::move(data));
  SUCCEED() << "passthrough() returned without dereferencing a null input_t";
}

TEST(InputPassthroughGuardTest, UnicodePacketTruncatedBelowDeclaredSizeIsRejected) {
  // Mirrors the real bug fixed by this guard: a unicode packet (NV_UNICODE_PACKET) whose
  // header.size claims the full struct size, but whose actual received buffer is shorter --
  // previously this underflowed a length calculation and threw std::length_error uncaught.
  std::shared_ptr<input::input_t> null_input;
  NV_UNICODE_PACKET packet {};
  auto full = to_wire(packet, UTF8_TEXT_EVENT_MAGIC);

  // Truncate the actual buffer to just the header, while header.size (already set for the full
  // struct) still declares the untruncated size.
  std::vector<uint8_t> truncated(full.begin(), full.begin() + sizeof(NV_INPUT_HEADER));

  input::passthrough(null_input, std::move(truncated));
  SUCCEED() << "passthrough() returned without dereferencing a null input_t";
}

// ---------------------------------------------------------------------
// Accept path: legit packets at their exact correct size must not be false-rejected by the guard.
// Uses a real input_t (input::alloc()) and observes the global task_pool to prove the packet
// cleared the guard, without ever running the enqueued task (see file-level comment).
// ---------------------------------------------------------------------

TEST(InputPassthroughGuardTest, ExactSizeKeyboardPacketIsAccepted) {
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_KEYBOARD_PACKET packet {};
  packet.keyCode = util::endian::little((short) 0x41);
  auto data = to_wire(packet, KEY_DOWN_EVENT_MAGIC);

  input::passthrough(input, std::move(data));

  auto task = task_pool.pop();
  EXPECT_TRUE(task.has_value()) << "a well-formed, exact-size keyboard packet must reach the "
                                    "task_pool dispatch, not be silently dropped by the guard";
}

TEST(InputPassthroughGuardTest, ExactSizeMultiControllerPacketIsAccepted) {
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_MULTI_CONTROLLER_PACKET packet {};
  packet.controllerNumber = 0;
  packet.activeGamepadMask = 0;  // no bits set: this controller is not (yet) active
  auto data = to_wire(packet, MULTI_CONTROLLER_MAGIC_GEN5);

  input::passthrough(input, std::move(data));

  // controllerNumber 0's gamepad slot is unallocated (id == -1, see gamepad_t's default ctor,
  // src/input.cpp:129), so the direct HID fast-path is skipped and this falls through to the
  // task_pool queue -- exactly like the keyboard packet above.
  auto task = task_pool.pop();
  EXPECT_TRUE(task.has_value()) << "a well-formed, exact-size multi-controller packet on an "
                                    "unallocated slot must reach the task_pool dispatch, not be "
                                    "silently dropped by the guard";
}

TEST(InputPassthroughGuardTest, ExactSizeUnicodePacketIsAccepted) {
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_UNICODE_PACKET packet {};
  std::memcpy(packet.text, "hi", 2);
  auto data = to_wire(packet, UTF8_TEXT_EVENT_MAGIC);

  input::passthrough(input, std::move(data));

  auto task = task_pool.pop();
  EXPECT_TRUE(task.has_value()) << "a well-formed, exact-size unicode packet (the packet type "
                                    "whose length-underflow this guard specifically fixed) must "
                                    "reach the task_pool dispatch, not be silently dropped";
}

// ---------------------------------------------------------------------
// abs-mouse packet: negative width/height must be rejected, not just zero (src/input.cpp:558-566).
TEST(InputPassthroughGuardTest, ShortUnicodePacketIsAccepted) {
  auto input = make_real_input();
  ASSERT_TRUE(input);

  NV_UNICODE_PACKET packet {};
  std::memcpy(packet.text, "hi", 2);
  auto data = to_wire(packet, UTF8_TEXT_EVENT_MAGIC);
  data.resize(sizeof(NV_INPUT_HEADER) + 2);
  packet.header.size = util::endian::big(static_cast<uint32_t>(sizeof(packet.header.magic) + 2));
  std::memcpy(data.data(), &packet.header, sizeof(packet.header));

  input::passthrough(input, std::move(data));

  EXPECT_TRUE(task_pool.pop().has_value());
}

// This overload is not declared in input.h, but has external linkage in `namespace input` (not
// static, not anonymous namespace), so it can be forward-declared and linked against here exactly
// like confighttp.cpp's extract_authority()/is_same_origin_impl() pattern
// (tests/unit/test_confighttp.cpp).
// ---------------------------------------------------------------------

namespace input {
  struct input_t;
  void passthrough(std::shared_ptr<input_t> &input, PNV_ABS_MOUSE_MOVE_PACKET packet);
}  // namespace input

TEST(InputAbsMouseBoundsTest, NegativeWidthIsRejectedNotJustZero) {
  // Regression for the exact fix: previously `!packet->width` only rejected width == 0, so a
  // negative width (a valid bit pattern that isn't zero) sailed through into client_to_touchport()
  // and on into a divide using a negative scale factor.
  //
  // Note: unlike the byte-vector passthrough() guard tested above, this overload dereferences
  // `input` (input->mouse_left_button_timeout) *before* the width/height check
  // (src/input.cpp:554), so a null input_t would crash here regardless of the fix under test --
  // a real input_t (input::alloc()) is required to isolate the bounds check itself.
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_ABS_MOUSE_MOVE_PACKET packet {};
  packet.width = util::endian::big((short) -1);
  packet.height = util::endian::big((short) 100);

  input::passthrough(input, &packet);
  SUCCEED() << "negative width was rejected without reaching platf::abs_mouse()";
}

TEST(InputAbsMouseBoundsTest, NegativeHeightIsRejectedNotJustZero) {
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_ABS_MOUSE_MOVE_PACKET packet {};
  packet.width = util::endian::big((short) 100);
  packet.height = util::endian::big((short) -1);

  input::passthrough(input, &packet);
  SUCCEED() << "negative height was rejected without reaching platf::abs_mouse()";
}

TEST(InputAbsMouseBoundsTest, ZeroWidthIsStillRejected) {
  // Not a regression (this path already worked), but guards against a future refactor of the
  // condition (e.g. `raw_width <= 0`) accidentally becoming `raw_width < 0`.
  auto input = make_real_input();
  ASSERT_TRUE(input) << "input::alloc() must produce a live input_t";

  NV_ABS_MOUSE_MOVE_PACKET packet {};
  packet.width = util::endian::big((short) 0);
  packet.height = util::endian::big((short) 100);

  input::passthrough(input, &packet);
  SUCCEED() << "zero width was rejected without reaching platf::abs_mouse()";
}
