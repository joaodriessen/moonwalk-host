#!/bin/bash
# live-vd-primary-flip.sh — RED/GREEN regression test for the out-of-box empty-extended-monitor
# defect: vd_helper's forceExtendMode() makes the virtual display a well-behaved EXTENDED
# display (deliberately anti-auto-mirror), but an extended display that is never MAIN shows an
# empty desktop to a fresh client -- no window, menu bar, or desktop icon ever lands there. This
# asserts vd_helper performs a PRIMARY FLIP at create time (VD becomes CGMainDisplayID(), the
# enabled physical(s) move aside in the same transaction) and restores the original main display
# at teardown. Ported semantics from the retired macos-dist/arrange_displays.sh -- see
# src/platform/macos/vd_helper.m's performPrimaryFlip()/restoreOriginalMainIfNeeded() doc
# comments for the WindowServer scars this encodes.
#
# THIS FLIPS THE REAL DISPLAY TOPOLOGY on the machine it runs on, for a few seconds -- that is
# the thing under test, and it is expected and sanctioned. The cleanup trap destroys the helper
# if it's still alive (which itself restores the original main, see the header comment on
# vd_helper.m's restoreOriginalMainIfNeeded()) and wakes the displays, so no run -- pass, fail,
# or interrupted -- leaves a flipped topology behind.
#
# Usage: live-vd-primary-flip.sh [path-to-vd_helper]
#   Defaults to $REPO/build/vd_helper. Pass an alternate path (e.g. a saved pre-change binary) to
#   run the RED half of a red/green pair without touching the current build output.
#
# Runs TWO scenarios back to back, each a full spawn/verify/teardown cycle against a clean
# baseline:
#   1) 1920x1080 (sub-threshold) -- must stay at native 1x: logical bounds == pixel mode == 1920x1080.
#   2) 2880x1800 (retina-class: both dims even, width >= 2560) -- must land at @2x: logical bounds
#      1440x900 (half), while CGDisplayModeGetPixelWidth/Height of the VD's current mode is still
#      2880x1800 (capture-facing pixel count unchanged either way -- see vd_helper.m Step 3 comment).
# Both scenarios also carry the original primary-flip assertions (main==VD, teardown restores
# baseline main) since the scale-mode fix and the flip fix share this one live harness.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${1:-$REPO/build/vd_helper}"
FPS=60

RESULT=0
fail() {
  echo "FAIL: $*" >&2
  RESULT=1
}

[ -x "$HELPER" ] || {
  echo "ABORT: '$HELPER' not found or not executable -- build it first:"
  echo "  cmake --build \"$REPO/build\" --target vd_helper -j\"\$(sysctl -n hw.ncpu)\""
  exit 2
}

# Pre-flight: never start with a leftover helper already on the machine -- we could never
# attribute a post-test topology to THIS run, and CGMainDisplayID()/online-list assertions below
# would be comparing against an already-mutated baseline.
if pgrep -fl vd_helper >/dev/null 2>&1; then
  echo "ABORT: vd_helper already running before the test started -- clean the machine first:"
  pgrep -fl vd_helper
  exit 2
fi

# Retain helper diagnostics when requested, including early create/readiness failures.
# The default remains a disposable trial directory.
if [ -n "${SKYLIGHT_VALIDATION_OUTPUT:-}" ]; then
  mkdir -p "$SKYLIGHT_VALIDATION_OUTPUT"
  WORK="$(mktemp -d "$SKYLIGHT_VALIDATION_OUTPUT/vd-XXXXXX")"
else
  WORK="$(mktemp -d)"
fi
HELPER_PID=""
CLEANED_UP=""

cleanup() {
  [ -n "$CLEANED_UP" ] && return
  CLEANED_UP=1
  echo "--- cleanup ---"

  if [ -n "$HELPER_PID" ] && kill -0 "$HELPER_PID" 2>/dev/null; then
    echo "cleanup: helper $HELPER_PID still alive -- sending destroy (its own teardown restores main)"
    printf 'destroy\n' >&3 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$HELPER_PID" 2>/dev/null || break
      sleep 0.3
    done
    if kill -0 "$HELPER_PID" 2>/dev/null; then
      echo "cleanup: helper still alive after destroy -- killing (topology may need a manual wake)"
      kill -TERM "$HELPER_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$HELPER_PID" 2>/dev/null || true
    fi
  fi

  # Wake displays unconditionally: a killed (not cleanly destroyed) helper never ran its own
  # teardown restore, and WindowServer can leave a stale online/main state until the next
  # reconfiguration or wake nudges it (same rationale as live-launch-abort-vd-cleanup.sh).
  caffeinate -u -t 3 >/dev/null 2>&1 || true
  sleep 1

  FINAL_MAIN="$(main_display_id 2>/dev/null || true)"
  echo "cleanup: main display id is now ${FINAL_MAIN:-unknown}"

  exec 3<&- 2>/dev/null || true
  exec 4<&- 2>/dev/null || true
  if [ -n "${SKYLIGHT_VALIDATION_OUTPUT:-}" ]; then
    echo "Evidence retained at $WORK"
  else
    rm -rf "$WORK"
  fi
  echo "--- cleanup done ---"
}
trap cleanup EXIT INT TERM

main_display_id() {
  cat > "$WORK/main_probe.swift" <<'SWIFT'
import CoreGraphics
print(CGMainDisplayID())
SWIFT
  swift "$WORK/main_probe.swift" 2>/dev/null
}

# STABLE identity of whatever is currently main, NOT its CGDirectDisplayID -- coordinator finding,
# 2026-08-14: WindowServer renumbers a physical display's id across VD create/destroy cycles, live,
# mid-session, with no user action (observed on this exact dev machine: 3 -> 222 -> 3 again across
# ordinary back-to-back flip/restore cycles). (vendor, model, serial, unit) survives that churn --
# mirrors src/platform/macos/vd_helper.m's StableDisplayKey. Prints "vendor model serial unit
# originX originY" as one space-separated line so a caller can compare identity and origin
# independently.
main_display_stable_key() {
  cat > "$WORK/main_key_probe.swift" <<'SWIFT'
import CoreGraphics
let d = CGMainDisplayID()
let b = CGDisplayBounds(d)
print("\(CGDisplayVendorNumber(d)) \(CGDisplayModelNumber(d)) \(CGDisplaySerialNumber(d)) \(CGDisplayUnitNumber(d)) \(Int(b.origin.x)) \(Int(b.origin.y))")
SWIFT
  swift "$WORK/main_key_probe.swift" 2>/dev/null
}

online_display_ids() {
  cat > "$WORK/online_probe.swift" <<'SWIFT'
import CoreGraphics
var displays = [CGDirectDisplayID](repeating: 0, count: 32)
var count: UInt32 = 0
CGGetOnlineDisplayList(32, &displays, &count)
for i in 0..<Int(count) { print(displays[i]) }
SWIFT
  swift "$WORK/online_probe.swift" 2>/dev/null
}

# Scale-mode probe (HiDPI fix): given a CGDirectDisplayID, prints
# "logicalW logicalH pixelW pixelH" -- CGDisplayBounds().size is logical POINTS (same space
# CGConfigureDisplayOrigin operates in), CGDisplayCopyDisplayMode(d)'s .pixelWidth/.pixelHeight
# is the retina-aware PIXEL backing size (same values sc_capture.m reads via
# CGDisplayModeGetPixelWidth/Height). Works on any active display id, main or not, so it can be
# called on the VD directly regardless of primary-flip outcome.
vd_mode_info() {
  local did="$1"
  cat > "$WORK/vd_mode_probe_$$.swift" <<SWIFT
import CoreGraphics
let d: CGDirectDisplayID = $did
let b = CGDisplayBounds(d)
var pw = 0
var ph = 0
if let mode = CGDisplayCopyDisplayMode(d) {
  pw = mode.pixelWidth
  ph = mode.pixelHeight
}
print("\(Int(b.size.width)) \(Int(b.size.height)) \(pw) \(ph)")
SWIFT
  swift "$WORK/vd_mode_probe_$$.swift" 2>/dev/null
}

# --- run_scenario: one full spawn/verify/teardown cycle -------------------------------------
# Args: WIDTH HEIGHT EXPECT_LOGICAL_W EXPECT_LOGICAL_H SCENARIO_LABEL
# EXPECT_LOGICAL_W/H is what CGDisplayBounds should report for the VD once vd_helper's Step 3
# scale policy has run: WIDTHxHEIGHT unchanged for a sub-threshold (1x) request, halved for a
# retina-class (>=2560, both dims even) request. The pixel-mode assertion always expects the
# full WIDTHxHEIGHT regardless of scenario -- capture is pixel-based either way (sc_capture.m).
run_scenario() {
  local WIDTH="$1" HEIGHT="$2" EXPECT_LOGICAL_W="$3" EXPECT_LOGICAL_H="$4" LABEL="$5"
  echo ""
  echo "=== Scenario: $LABEL (${WIDTH}x${HEIGHT}, expect logical ${EXPECT_LOGICAL_W}x${EXPECT_LOGICAL_H}, pixel ${WIDTH}x${HEIGHT}) ==="

  # --- 1) Baseline ---------------------------------------------------------------------------
  BASELINE_MAIN="$(main_display_id)"
[ -n "$BASELINE_MAIN" ] || { echo "ABORT: could not read a baseline CGMainDisplayID()"; exit 2; }
echo "baseline main display: $BASELINE_MAIN (raw id -- informational only, see stable key below)"

# The identity that actually has to survive the test is the STABLE key, not this raw id (which can
# -- and, per the coordinator's live finding, does -- legitimately renumber mid-run). Captured
# alongside the raw id purely for log correlation.
BASELINE_MAIN_KEY="$(main_display_stable_key)"
[ -n "$BASELINE_MAIN_KEY" ] || { echo "ABORT: could not read a baseline main-display stable key"; exit 2; }
BASELINE_MAIN_IDENTITY="$(printf '%s\n' "$BASELINE_MAIN_KEY" | cut -d' ' -f1-4)"
echo "baseline main display stable identity (vendor model serial unit): $BASELINE_MAIN_IDENTITY"

# Baseline online-display count, pre-VD: every one of these is necessarily a real physical (the
# VD doesn't exist yet), so this is the expected "physical(s) moved aside" count the flip's
# participant discriminator should report later (§3b) -- a cheap ground truth for "the current
# topology's real physicals were neither wrongly excluded nor wrongly padded."
BASELINE_ONLINE_COUNT="$(online_display_ids | grep -c .)"
echo "baseline online display count (all real physicals): $BASELINE_ONLINE_COUNT"

# --- 2) Spawn the helper, bidirectional via a pair of FIFOs --------------------------------
# `coproc` would be the obvious tool here but macOS ships bash 3.2 (no coproc, added in 4.0) and
# this repo has no bundled newer bash -- so wire it up with mkfifo instead. Opening each FIFO
# read-write on our own fd (3 for the helper's stdin, 4 for its stdout) BEFORE spawning the
# helper means our end never blocks on open and the FIFO never sees a spurious EOF between the
# helper's own opens, regardless of exact spawn/read ordering.
IN_FIFO="$WORK/helper.in.${WIDTH}x${HEIGHT}"
OUT_FIFO="$WORK/helper.out.${WIDTH}x${HEIGHT}"
mkfifo "$IN_FIFO" "$OUT_FIFO"
exec 3<>"$IN_FIFO"
exec 4<>"$OUT_FIFO"

echo "spawning: $HELPER $WIDTH $HEIGHT $FPS"
"$HELPER" "$WIDTH" "$HEIGHT" "$FPS" <"$IN_FIFO" >"$OUT_FIFO" 2>"$WORK/helper.stderr.log" &
HELPER_PID=$!

# This script spawns vd_helper directly (no VD_HELPER_TOTAL_SEC / idle-watchdog involved -- that
# budget lives in virtual_display.m's spawn_vd_helper_and_read_output(), not here), so the only
# deadline in play is this script's own read timeout. 2026-08-14 N1 fix: the primary flip now runs
# BEFORE vd_helper reports the displayID (moved back to its e1c7c981 position -- see vd_helper.m's
# Step 4 doc comment), so this read has to sit through the flip's own worst case too: ~3-4s of
# fixed pre-flip settle/poll cost (Steps 1-3) plus up to ~2.9s of flip retries (0.5s wake settle +
# 6 x 0.4s attempts) -- call it ~7s worst case, healthy. 30s gives >4x headroom over that.
VD_ID=""
if ! IFS= read -r -t 30 VD_ID <&4; then
  fail "helper produced no stdout line (displayID) within 30s -- treating as create failure"
  exit 1
fi
echo "helper stdout: displayID line = '$VD_ID' (pid $HELPER_PID)"

if [ -z "$VD_ID" ] || [ "$VD_ID" = "0" ]; then
  fail "vd_helper reported displayID=0 (create/readiness failure) -- cannot exercise the flip"
  exit 1
fi

# --- 3) RED/GREEN assertion: main == the new VD ----------------------------------------------
# 2026-08-14 N1 fix: vd_helper now attempts (and either verifies or gives up on, after 6 tries)
# the primary flip BEFORE reporting the displayID line -- reverting the brief post-report
# placement a prior pass used to dodge the parent's old flat spawn-timeout budget, which instead
# let a WindowServer reconfigure land inside the parent's capture-start window (the
# unprovable-black-screen class, display_device.cpp:804-810). So by the time VD_ID was read above,
# the flip has ALREADY run to completion (verified or not) -- this loop is now mostly a formality
# that should pass on attempt 1, kept as a small safety margin for residual propagation lag
# between the just-completed transaction landing and a fresh `swift` subprocess query observing
# it. 16 x 0.5s = 8s is generous headroom, not a "wait for the flip to happen" budget anymore.
FLIPPED=""
for attempt in $(seq 1 16); do
  CUR_MAIN="$(main_display_id)"
  echo "verify attempt $attempt: main=$CUR_MAIN want=$VD_ID"
  if [ "$CUR_MAIN" = "$VD_ID" ]; then
    FLIPPED=1
    break
  fi
  sleep 0.5
done

if [ -n "$FLIPPED" ]; then
  echo "PASS(flip): main display is the VD ($VD_ID) -- primary flip verified"
else
  fail "primary flip not verified: main never became VD $VD_ID (stayed at $CUR_MAIN) -- this is the RED result against a pre-flip binary"
fi

# --- 3b) Participant-discriminator sanity (cheap, not a full topology model) -----------------
# Confirms the discriminator actually ran and didn't misclassify anything for THIS topology:
#   - the winning attempt's own log line reports moving exactly BASELINE_ONLINE_COUNT physicals
#     (nothing wrongly excluded, nothing wrongly padded in);
#   - zero "carries our own vendor signature" skips (no leaked Skylight VD is on this machine, so
#     none should have been found/excluded).
#
# HEADLESS SKIP (2026-08-14, second coordinator finding): main()'s Step 4 in vd_helper.m skips
# performPrimaryFlip() ENTIRELY -- logging "already main (headless) -- no primary flip needed"
# instead -- whenever the VD is already CGMainDisplayID() the instant it's created (i.e. it was
# the ONLY display CGGetActiveDisplayList saw at that moment). Observed live on this exact dev
# machine: the physical can drop out of the ACTIVE list between this script's baseline probe and
# vd_helper's own internal check a few hundred ms later (the same id-churn volatility documented
# elsewhere in this file), so a real, single-external-display topology can legitimately hit the
# headless path even though BASELINE_ONLINE_COUNT saw the physical as online moments earlier.
# That is a valid, pre-existing, INTENDED code path -- not a flip failure -- so no "Primary flip
# attempt" log line, and hence no WIN_LINE, is expected to exist for it. Detect it explicitly and
# skip (not fail) the participant-count check; still expect zero vendor-signature skips either way
# (that check doesn't depend on a flip having run at all).
if [ -n "$FLIPPED" ] && grep -q "already main (headless)" "$WORK/helper.stderr.log"; then
  echo "SKIP(participant-count): vd_helper reports the VD ($VD_ID) was already main at creation (headless skip) -- no primary-flip attempt ever ran, so there is no participant log line to sanity-check this run"
elif [ -n "$FLIPPED" ]; then
  WIN_LINE="$(grep "main is now $VD_ID" "$WORK/helper.stderr.log" | tail -1)"
  echo "winning attempt log line: $WIN_LINE"
  WIN_COUNT="$(printf '%s\n' "$WIN_LINE" | sed -n 's/.*attempt [0-9]*: \([0-9]*\) physical(s) moved aside.*/\1/p')"
  if [ "$WIN_COUNT" = "$BASELINE_ONLINE_COUNT" ]; then
    echo "PASS(participant-count): flip moved $WIN_COUNT physical(s), matches baseline online count ($BASELINE_ONLINE_COUNT)"
  else
    fail "flip moved $WIN_COUNT physical(s) but baseline online count was $BASELINE_ONLINE_COUNT -- discriminator excluded or padded something for this topology"
  fi
fi
if [ -n "$FLIPPED" ]; then
  VENDOR_SKIPS="$(grep -c 'carries our own vendor signature' "$WORK/helper.stderr.log")"
  if [ "$VENDOR_SKIPS" = "0" ]; then
    echo "PASS(no-leaked-vd): no vendor-signature exclusions logged (no leaked Skylight VD on this machine)"
  else
    fail "unexpected vendor-signature exclusion(s) logged ($VENDOR_SKIPS) -- investigate before treating this run as clean"
  fi
fi

# --- 3c) Scale/HiDPI mode assertion (the fix under test) ---------------------------------------
# Query the VD directly by its own CGDirectDisplayID -- works regardless of whether the primary
# flip made it main, and reflects vd_helper's Step 3 scale-policy outcome, which has already run
# to completion by the time VD_ID was read (Step 3 precedes the stdout report -- see vd_helper.m's
# Step 4 doc comment).
MODE_INFO="$(vd_mode_info "$VD_ID")"
echo "VD $VD_ID mode info (logicalW logicalH pixelW pixelH): $MODE_INFO"
ACTUAL_LOGICAL_W="$(printf '%s\n' "$MODE_INFO" | awk '{print $1}')"
ACTUAL_LOGICAL_H="$(printf '%s\n' "$MODE_INFO" | awk '{print $2}')"
ACTUAL_PIXEL_W="$(printf '%s\n' "$MODE_INFO" | awk '{print $3}')"
ACTUAL_PIXEL_H="$(printf '%s\n' "$MODE_INFO" | awk '{print $4}')"

if [ "$ACTUAL_LOGICAL_W" = "$EXPECT_LOGICAL_W" ] && [ "$ACTUAL_LOGICAL_H" = "$EXPECT_LOGICAL_H" ]; then
  echo "PASS(logical-scale): VD logical bounds are ${ACTUAL_LOGICAL_W}x${ACTUAL_LOGICAL_H} (want ${EXPECT_LOGICAL_W}x${EXPECT_LOGICAL_H})"
else
  fail "VD logical bounds are ${ACTUAL_LOGICAL_W}x${ACTUAL_LOGICAL_H}, want ${EXPECT_LOGICAL_W}x${EXPECT_LOGICAL_H} for $LABEL -- this is the RED result against the pre-fix unconditional-1x binary for a retina-class request"
fi

if [ "$ACTUAL_PIXEL_W" = "$WIDTH" ] && [ "$ACTUAL_PIXEL_H" = "$HEIGHT" ]; then
  echo "PASS(pixel-mode): VD current-mode pixel size is ${ACTUAL_PIXEL_W}x${ACTUAL_PIXEL_H} (want ${WIDTH}x${HEIGHT}, unchanged regardless of scale)"
else
  fail "VD current-mode pixel size is ${ACTUAL_PIXEL_W}x${ACTUAL_PIXEL_H}, want ${WIDTH}x${HEIGHT} -- capture-facing resolution regressed"
fi

# --- 4) Teardown: destroy, then assert restore -------------------------------------------------
echo "sending destroy"
printf 'destroy\n' >&3

RELEASED=""
for _ in $(seq 1 20); do
  if IFS= read -r -t 1 LINE <&4 2>/dev/null; then
    echo "helper stdout: $LINE"
    case "$LINE" in
      "released "*) RELEASED=1 ;;
    esac
    [ -n "$RELEASED" ] && break
  else
    kill -0 "$HELPER_PID" 2>/dev/null || break
  fi
done
[ -n "$RELEASED" ] || fail "never saw a 'released <id>' ACK on stdout within ~20s"

# Wait for the process to actually exit (bounded).
for _ in $(seq 1 20); do
  kill -0 "$HELPER_PID" 2>/dev/null || break
  sleep 0.3
done
if kill -0 "$HELPER_PID" 2>/dev/null; then
  fail "helper process $HELPER_PID still alive >6s after the released ACK"
else
  echo "helper process $HELPER_PID exited"
fi
HELPER_PID=""  # exited on its own -- cleanup trap has nothing to kill

# Wake before comparing: WindowServer can defer removing a released VD from the online list
# while displays are asleep (same rationale as live-launch-abort-vd-cleanup.sh).
caffeinate -u -t 3
sleep 2

AFTER_MAIN="$(main_display_id)"
echo "post-destroy main display: $AFTER_MAIN (raw id -- informational only; baseline raw id was $BASELINE_MAIN)"

# Assert by STABLE identity + origin, not raw id (coordinator finding, 2026-08-14): comparing raw
# CGDirectDisplayIDs here produced a false FAIL against a functionally-correct restore -- the id
# renumbered mid-run (a real, observed WindowServer behavior on this machine, unrelated to the
# code under test), while the SAME physical, at the SAME (0,0) origin, correctly ended up main
# again. See main_display_stable_key()'s doc comment above.
AFTER_MAIN_KEY="$(main_display_stable_key)"
AFTER_MAIN_IDENTITY="$(printf '%s\n' "$AFTER_MAIN_KEY" | cut -d' ' -f1-4)"
AFTER_MAIN_ORIGIN="$(printf '%s\n' "$AFTER_MAIN_KEY" | cut -d' ' -f5-6)"
echo "post-destroy main display stable identity: $AFTER_MAIN_IDENTITY, origin: ($AFTER_MAIN_ORIGIN) (baseline identity was $BASELINE_MAIN_IDENTITY)"

if [ "$AFTER_MAIN_IDENTITY" = "$BASELINE_MAIN_IDENTITY" ]; then
  echo "PASS(stable-identity-restored): post-destroy main is the same physical identity as baseline, independent of any CGDirectDisplayID renumbering"
else
  fail "post-destroy main display identity differs from baseline (want '$BASELINE_MAIN_IDENTITY', got '$AFTER_MAIN_IDENTITY') -- not just an id renumber, a DIFFERENT (or no) physical ended up main"
fi

if [ "$AFTER_MAIN_ORIGIN" = "0 0" ]; then
  echo "PASS(origin-restored): post-destroy main display origin is (0,0)"
else
  fail "post-destroy main display origin is ($AFTER_MAIN_ORIGIN), not (0,0) -- restore did not land the physical back at its expected origin"
fi

AFTER_ONLINE="$(online_display_ids)"
if printf '%s\n' "$AFTER_ONLINE" | grep -qx "$VD_ID"; then
  fail "VD $VD_ID still present in CGGetOnlineDisplayList after destroy+wake"
else
  echo "VD $VD_ID no longer in the online display list"
fi

# Close this scenario's fds so the next scenario's mkfifo/exec pair starts clean. Guarded --
# HELPER_PID is already "" here (helper exited on its own above), so the global cleanup trap has
# nothing left to do for this scenario if the script exits normally after this point.
exec 3<&- 2>/dev/null || true
exec 4<&- 2>/dev/null || true

echo "=== Scenario $LABEL done (RESULT so far: $RESULT) ==="
}

# --- Scenario 1: sub-threshold (the pre-existing case) --------------------------------------
# 1920x1080 is not retina-class (width < 2560) -- must stay at native 1x: logical == pixel ==
# 1920x1080, exactly today's pre-fix behavior for this size.
run_scenario 1920 1080 1920 1080 "sub-threshold-1x"

# --- Scenario 2: retina-class (the HiDPI fix) -------------------------------------------------
# 2880x1800: both dimensions even, width >= 2560 -- must land at @2x: logical bounds halved to
# 1440x900 while the current mode's pixel size (what sc_capture.m actually reads) stays 2880x1800.
run_scenario 2880 1800 1440 900 "retina-class-2x"

if [ "$RESULT" = "0" ]; then
  echo ""
  echo "PASS: both scenarios verified (primary flip, scale policy, teardown restore, VD cleanup)"
else
  echo ""
  echo "--- one or more assertions FAILED across scenarios, see FAIL lines above ---"
fi
exit "$RESULT"
