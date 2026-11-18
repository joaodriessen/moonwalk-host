/**
 * @file tests/unit/platform/test_sc_capture_retry.cpp
 * @brief Test src/platform/macos/sc_capture_retry.h -- the pure, Foundation-free predicate that
 *        decides whether an SCK stop-error is the transient Mode-2 enumeration race
 *        (docs/design/2026-07-12-black-screen-permanent-fix.md §3) that sc_capture.m's bounded
 *        start-retry should catch, versus a genuine/unrelated stop that must keep failing the
 *        session exactly as before this fix.
 * @details No ScreenCaptureKit/live-display dependency -- this header has zero macOS-API surface,
 *          so the predicate itself is fully exercisable here even though sc_capture.m (its only
 *          production caller) is macOS-only.
 */
#include "../../tests_common.h"

#include <src/platform/macos/sc_capture_retry.h>

using namespace platf::macos;

TEST(SCCaptureRetry, MatchesExactObservedRaceMessage) {
  // The verbatim string live logs show SCK reporting ~21ms after "Capture started successfully"
  // (docs/design/2026-07-12-black-screen-permanent-fix.md §1 evidence).
  EXPECT_TRUE(is_transient_sck_enumeration_race("Failed to find any displays or windows to capture"));
}

TEST(SCCaptureRetry, MatchesCaseInsensitively) {
  EXPECT_TRUE(is_transient_sck_enumeration_race("FAILED TO FIND ANY DISPLAYS OR WINDOWS TO CAPTURE"));
  EXPECT_TRUE(is_transient_sck_enumeration_race("failed to find any displays or windows to capture"));
}

TEST(SCCaptureRetry, MatchesAsASubstringOfALongerNSErrorDescription) {
  // NSError.localizedDescription is frequently wrapped/prefixed by the framework; the predicate
  // must still fire on a substring match, not require an exact whole-string match.
  EXPECT_TRUE(is_transient_sck_enumeration_race(
    "The operation couldn't be completed. (com.apple.ScreenCaptureKit.SCStreamErrorDomain error 4.) "
    "Failed to find any displays or windows to capture."
  ));
}

TEST(SCCaptureRetry, DoesNotMatchUnrelatedErrors) {
  // These must keep failing the session immediately, unchanged from before this fix -- a
  // false-positive retry on a real, unrelated failure would just delay the correct behavior.
  EXPECT_FALSE(is_transient_sck_enumeration_race("User declined screen recording permission"));
  EXPECT_FALSE(is_transient_sck_enumeration_race("The operation couldn't be completed."));
  EXPECT_FALSE(is_transient_sck_enumeration_race("Stream stopped by the user"));
  EXPECT_FALSE(is_transient_sck_enumeration_race(""));
}

TEST(SCCaptureRetry, DoesNotMatchAPartialPhrase) {
  // Guards against an overly broad match (e.g. just "displays" or "capture") that could
  // false-positive on genuinely different errors mentioning similar words.
  EXPECT_FALSE(is_transient_sck_enumeration_race("Failed to find the display"));
  EXPECT_FALSE(is_transient_sck_enumeration_race("No windows available to capture"));
}
