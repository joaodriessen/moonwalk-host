/**
 * @file src/platform/macos/sc_capture_retry.h
 * @brief Pure predicate for the ScreenCaptureKit start-retry decision (no ObjC/Foundation
 *        dependency), so it can be exercised directly from a plain C++ unit test without a live
 *        ScreenCaptureKit session.
 * @details docs/design/2026-07-12-black-screen-permanent-fix.md §3 "Fix for Mode 2 — SCK race
 *          must never kill the daemon". SCK is observed (live logs) to intermittently log
 *          "Capture started successfully" and then, ~21ms later, fail with "Failed to find any
 *          displays or windows to capture" — its own enumeration lagging the just-applied display
 *          transaction, not a real failure (a healthy session on the same display proves it is
 *          capturable). sc_capture.m matches this exact, verbatim SCK message to decide whether a
 *          stop-with-error is this specific transient race (-> bounded retry) or a genuine,
 *          unrelated stop (-> fail the session cleanly, unchanged from before this fix).
 */
#pragma once

#include <algorithm>
#include <cctype>
#include <iterator>
#include <string>

namespace platf::macos {

  // Case-insensitive substring match against the exact SCK error text this race is known to
  // produce. Deliberately narrow (exact-phrase match, not a broad heuristic) so unrelated SCK
  // errors -- e.g. permission-denied, user-declined, a real display disconnect -- are NOT treated
  // as retryable and continue to fail the session immediately, exactly as before this fix.
  inline bool is_transient_sck_enumeration_race(const std::string &error_description) {
    static const std::string needle = "failed to find any displays or windows to capture";

    if (error_description.size() < needle.size()) {
      return false;
    }

    std::string haystack;
    haystack.reserve(error_description.size());
    std::transform(error_description.begin(), error_description.end(), std::back_inserter(haystack), [](unsigned char c) {
      return static_cast<char>(std::tolower(c));
    });

    return haystack.find(needle) != std::string::npos;
  }

}  // namespace platf::macos
