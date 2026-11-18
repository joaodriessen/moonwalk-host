/**
 * @file tests/unit/test_rtsp.cpp
 * @brief Test src/rtsp.* -- regression coverage for what's genuinely unit-reachable, honest
 * documentation of what is not.
 *
 * Most of the wave-A/B RTSP hardening (launch-field clamps A1/A2/A3/A5, the ANNOUNCE single-use
 * guard) lives inside `cmd_announce()`, a single large free function in src/rtsp.cpp that takes a
 * live `tcp::socket &`, a moonlight-common-c `RTSP_MESSAGE` PDU, and on the "valid input" path
 * goes on to spawn a real streaming session (process launch, capture, encoder init). There is no
 * seam here that lets a unit test drive just the validation logic:
 *   - Constructing a well-formed `msg_t` (util::safe_ptr<RTSP_MESSAGE, free_msg>) requires
 *     building a moonlight-common-c RTSP_MESSAGE with a populated OPTION_ITEM linked list and a
 *     raw SDP-style payload buffer -- there is no builder for this in the codebase or tests today.
 *   - `respond()` writes directly to the passed `tcp::socket&`; exercising the "valid input"
 *     branch would require either a real connected socket pair or accepting that the function
 *     then falls through into real session/process-launch side effects, which is unsafe and
 *     unrepresentative for a unit test.
 *   - The clamp checks themselves (`config.packetsize < 64 || > 65535`, `packetDuration < 1 ||
 *     > 1000`, `framerate < 1 || > 1000`, `width/height < 1 || > 65535`) are plain inline
 *     `if`-statements in the middle of `cmd_announce()`, not separable pure functions -- there is
 *     nothing to forward-declare and link against without editing src/rtsp.cpp to extract them
 *     (out of scope for this test-only pass; tests must not change src/).
 *
 * This means A1/A2/A3/A5 (the launch-field clamps) remain INTEGRATION-only coverage today. What
 * IS genuinely unit-reachable, and covered below, is the ANNOUNCE single-use guard's actual state:
 * `launch_session_t::consumed` is a plain `std::atomic<bool>` field on a public, freely
 * constructible struct (src/rtsp.h) -- `cmd_announce()`'s guard is exactly
 * `if (session.consumed.exchange(true)) { reject-as-403 }`. Testing the field's exchange semantics
 * directly on the real production type is a legitimate, non-vacuous regression test for the
 * invariant the fix relies on (as opposed to reimplementing the guard's logic in the test, which
 * would prove nothing about the shipped code).
 *
 * TODO (documented gap, needs a real harness, not faked here):
 *   - A1: x-nv-video[0].packetSize outside [64, 65535] must 400 (rtsp.cpp:999-1003); legit 1024
 *     must pass.
 *   - A2: x-nv-aqos.packetDuration outside [1, 1000] must 400 (rtsp.cpp:989-993); legit 5 must
 *     pass.
 *   - A3: x-nv-video[0].maxFPS outside [1, 1000] must 400 (rtsp.cpp:1021-1025); legit 60 must pass.
 *   - A5: x-nv-video[0].clientViewportWd/Ht outside [1, 65535] (either dimension) must 400
 *     (rtsp.cpp:1015-1020); legit 1920x1080 must pass.
 *   Exercising these needs either (a) extracting the parse+clamp logic in cmd_announce() into a
 *   pure, header-declared helper (a src/ change, out of scope here), or (b) a full RTSP-over-TCP
 *   test harness that builds a real ANNOUNCE request and asserts on the 400 response over a real
 *   socket pair, which does not exist in this test suite yet.
 */
#include "../tests_common.h"

#include <boost/asio/error.hpp>

#include <src/rtsp.h>

// ---------------------------------------------------------------------
// launch_session_t::consumed -- ANNOUNCE single-use guard (wave-B fix).
//
// cmd_announce() (src/rtsp.cpp:915) does:
//     if (session.consumed.exchange(true)) { respond(..., 403, "Forbidden", ...); return; }
// Two RTSP TCP connections racing in on the same pending launch session must not both proceed:
// the first exchange() call must observe `false` (proceed to spawn the session) and flip the
// flag; every subsequent call, from any connection, must observe `true` (get rejected).
// ---------------------------------------------------------------------

TEST(LaunchSessionConsumedTest, FreshSessionStartsUnconsumed) {
  rtsp_stream::launch_session_t session {};
  EXPECT_FALSE(session.consumed.load());
}

TEST(LaunchSessionConsumedTest, FirstExchangeReturnsFalseAndConsumes) {
  rtsp_stream::launch_session_t session {};
  bool was_already_consumed = session.consumed.exchange(true);
  EXPECT_FALSE(was_already_consumed) << "the first ANNOUNCE for a fresh launch session must be allowed to proceed";
  EXPECT_TRUE(session.consumed.load());
}

TEST(LaunchSessionConsumedTest, SecondExchangeReturnsTrue_DuplicateAnnounceMustBeRejected) {
  rtsp_stream::launch_session_t session {};
  session.consumed.exchange(true);  // first ANNOUNCE consumes it

  bool was_already_consumed = session.consumed.exchange(true);
  EXPECT_TRUE(was_already_consumed) << "a second ANNOUNCE on an already-consumed launch session "
                                        "must observe consumed==true and be rejected with 403, "
                                        "matching cmd_announce()'s guard at rtsp.cpp:915";
}

TEST(LaunchSessionConsumedTest, RepeatedExchangesAfterConsumptionAlwaysReturnTrue) {
  // Simulates N racing TCP connections all hitting ANNOUNCE after the first has already won:
  // every one of them must see consumed==true, not just the second.
  rtsp_stream::launch_session_t session {};
  session.consumed.exchange(true);

  for (int i = 0; i < 5; ++i) {
    EXPECT_TRUE(session.consumed.exchange(true)) << "iteration " << i;
  }
}

// ---------------------------------------------------------------------
// should_retry_bind() -- recovery-seatbelt bind-retry decision (P1, docs/design/
// 2026-07-12-black-screen-permanent-fix.md, Mode 3). A pure, header-declared helper -- exactly
// the kind of extraction the file-header comment above says A1/A2/A3/A5 are missing -- so it is
// directly unit-testable without a real socket or a real port collision.
// ---------------------------------------------------------------------

TEST(ShouldRetryBindTest, RetriesOnAddressInUseBelowMaxAttempts) {
  boost::system::error_code ec = boost::asio::error::address_in_use;
  EXPECT_TRUE(rtsp_stream::should_retry_bind(ec, /* attempt = */ 1, /* max_attempts = */ 5));
  EXPECT_TRUE(rtsp_stream::should_retry_bind(ec, /* attempt = */ 4, /* max_attempts = */ 5));
}

TEST(ShouldRetryBindTest, DoesNotRetryOnceMaxAttemptsReached) {
  boost::system::error_code ec = boost::asio::error::address_in_use;
  EXPECT_FALSE(rtsp_stream::should_retry_bind(ec, /* attempt = */ 5, /* max_attempts = */ 5))
    << "attempt == max_attempts must be the last try, not another retry";
  EXPECT_FALSE(rtsp_stream::should_retry_bind(ec, /* attempt = */ 6, /* max_attempts = */ 5));
}

TEST(ShouldRetryBindTest, DoesNotRetryOtherErrorsEvenOnFirstAttempt) {
  // Only EADDRINUSE is a plausible "previous instance still draining" race; any other bind
  // failure (bad address, permission denied, ...) is a real, non-transient error and must fail
  // fast instead of burning multiple seconds retrying something that will never succeed.
  EXPECT_FALSE(rtsp_stream::should_retry_bind(boost::asio::error::access_denied, 1, 5));
  EXPECT_FALSE(rtsp_stream::should_retry_bind(boost::asio::error::invalid_argument, 1, 5));
  EXPECT_FALSE(rtsp_stream::should_retry_bind(boost::system::error_code {}, 1, 5))
    << "a success (no-error) code is not a retry condition";
}

TEST(AudioStreamParameters, NativeStereoDoesNotAdvertiseUnsupportedCustomOrSurroundLayouts) {
  const auto sdp = rtsp_stream::audio_stream_parameters(2, "642014523");
  EXPECT_NE(sdp.find("surround-params=21101"), std::string::npos);
  EXPECT_EQ(sdp.find("surround-params=6"), std::string::npos);
  EXPECT_EQ(sdp.find("surround-params=8"), std::string::npos);
  EXPECT_EQ(std::count(sdp.begin(), sdp.end(), '\n'), 2);
}

TEST(AudioStreamParameters, ExplicitMultichannelInputRetainsItsLayouts) {
  const auto sdp = rtsp_stream::audio_stream_parameters(8, "642014523");
  EXPECT_NE(sdp.find("surround-params=21101"), std::string::npos);
  EXPECT_NE(sdp.find("surround-params=6"), std::string::npos);
  EXPECT_NE(sdp.find("surround-params=8"), std::string::npos);
  EXPECT_EQ(std::count(sdp.begin(), sdp.end(), '\n'), 8);
}
