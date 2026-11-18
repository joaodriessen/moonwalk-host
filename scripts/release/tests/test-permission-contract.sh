#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
SWIFT_PROTOCOL="$REPO/macos-dist/SkylightMenu/Sources/SkylightMenu/SkylightControlProtocol.swift"
HOST="$REPO/src/platform/macos/xpc_control.mm"
MISC="$REPO/src/platform/macos/misc.mm"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ "$(rg -n '^[[:space:]]*reply\(CGRequestScreenCaptureAccess\(\)' "$REPO/src" | wc -l | tr -d ' ')" = 1 ] ||
  fail "Screen Recording prompt exists outside its explicit XPC selector"
[ "$(rg -n '^[[:space:]]*BOOL granted = AXIsProcessTrustedWithOptions' "$REPO/src" | wc -l | tr -d ' ')" = 1 ] ||
  fail "Accessibility prompt exists outside its explicit XPC selector"

grep -Fq 'requestScreenRecording(withReply' "$SWIFT_PROTOCOL" || fail "Swift XPC protocol lacks Screen Recording request"
grep -Fq 'requestAccessibility(withReply' "$SWIFT_PROTOCOL" || fail "Swift XPC protocol lacks Accessibility request"
grep -Fq 'requestScreenRecordingWithReply' "$HOST" || fail "host lacks Screen Recording request selector"
grep -Fq 'requestAccessibilityWithReply' "$HOST" || fail "host lacks Accessibility request selector"

PREFLIGHT="$(sed -n '/bool preflight_screen_capture_access()/,/^  }/p' "$MISC")"
[[ "$PREFLIGHT" != *'CGRequestScreenCaptureAccess()'* ]] || fail "streaming preflight still prompts"

STARTUP="$(sed -n '/std::unique_ptr<deinit_t> init()/,/return std::make_unique<deinit_t>();/p' "$MISC")"
[[ "$STARTUP" != *'CGRequestScreenCaptureAccess()'* ]] || fail "daemon startup still prompts for Screen Recording"
[[ "$STARTUP" != *'AXIsProcessTrustedWithOptions'* ]] || fail "daemon startup still prompts for Accessibility"

SCREEN_REQUEST="$(sed -n '/requestScreenRecordingWithReply/,/^}/p' "$HOST")"
ACCESSIBILITY_REQUEST="$(sed -n '/requestAccessibilityWithReply/,/^}/p' "$HOST")"
[[ "$SCREEN_REQUEST" == *'CGRequestScreenCaptureAccess()'* ]] || fail "Screen Recording selector does not request access"
[[ "$ACCESSIBILITY_REQUEST" == *'AXIsProcessTrustedWithOptions'* ]] || fail "Accessibility selector does not request access"

echo "PASS: macOS permission prompts are owner initiated"
