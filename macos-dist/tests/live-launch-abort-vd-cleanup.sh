#!/bin/bash
# live-launch-abort-vd-cleanup.sh — regression test for the 2026-08-14 launch-abort VD leak.
# A /launch that fails in prep-cmds (missing script) must NOT leave vd_helper / a virtual
# display alive, and the daemon must remain retryable.
#
# THIS IS THE RELEASE ACCEPTANCE GATE for the 2026-08-14 VD-leak regression. It runs on ANY Mac
# that has the installed, signed `/Applications/Skylight.app` bundle, Screen Recording granted
# to it, and the ability for the menu app to open -- not only the machine that originally
# reproduced the bug. It is NOT part of the default test suites (name prefix `live-`) and MUST
# be run manually: it mutates the live daemon config/state for its duration and drives the real
# installed app.
#
# WHY THIS TARGETS THE INSTALLED APP (not a bare `build/sunshine` spawn): main.cpp's capture
# gate (docs/design/2026-07-19-daemon-lifecycle-coupling.md #2B.1) requires a launchd-vended
# `com.example.lumen.xpc`/`io.github.joaodriessen.skylight.daemon` Mach service AND a code-
# signature-validated SkylightMenu peer to attach within 10s, or the daemon self-shuts-down
# before ever starting mDNS/HTTP (main.cpp:406-430). A daemon launched bare from a terminal can
# never satisfy this (xpc_control.h's own doc comment: listener setup no-ops when the Mach
# service isn't launchd-vended) -- confirmed live, twice, 2026-08-14. The installed, launchd-
# registered, Gatekeeper-signed `/Applications/Skylight.app` (menu app + daemon helper) is the
# ONLY context that legitimately passes this gate outside of Task 10's real hardware round. This
# is a deliberate conductor decision, not a workaround: the gate is a safety property and is not
# bypassed here.
#
# RED = run against the pre-fix installed bundle (built 2026-08-14 00:33, before Task 3's
# display_device::destroy_virtual_display() fix landed in src/). GREEN = rerun after a release
# rebuild ships the fix into a reinstalled bundle (Task 9/10). Not part of the default suite
# (name prefix `live-`); mutates the owner's live daemon config/state for its duration -- backs
# up both, restores byte-identical, and quits the app again on exit no matter what.
#
# Failure trigger is a `global_prep_cmd` pointing at a script that does not exist on disk. If the
# live conf already has one uncommented (e.g. the owner-machine defect from
# dossier-prepcmd-failure.md #4, or any leftover from a prior manual repro), that entry is reused
# as-is -- today's behavior. Otherwise -- the normal clean-install case, where the shipped default
# conf has no global_prep_cmd at all -- this harness injects one pointing at a nonexistent script
# under its own mktemp workdir, so the same failure mode reproduces on a clean machine too. Either
# way the EXIT/INT/TERM trap restores the live conf byte-identical when the run ends.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIVE_CONF="$HOME/.config/skylight/sunshine.conf"
LIVE_STATE="$HOME/.config/skylight/sunshine_state.json"
DAEMON_LABEL="io.github.joaodriessen.skylight.daemon"
APP_PATH="/Applications/Skylight.app"
PORT=47989
HTTPS_PORT=$((PORT - 5))
HTTP_PORT=$PORT  # PORT_HTTP offset is 0 (nvhttp.h:41) -- plain HTTP, no TLS.
# /serverinfo on the HTTPS listener requires a client cert at the TLS layer itself
# (verify_fail_if_no_peer_cert, nvhttp.cpp:93) -- a certless curl gets a bare TLS/recv failure,
# not a clean HTTP response, so readiness/retryability polls below deliberately use the
# unauthenticated plain-HTTP /serverinfo (nvhttp.cpp:2412) instead. Confirmed live 2026-08-14:
# the https-without-cert poll produced false "daemon never answered" aborts even while the
# daemon was healthy and fully serving on the plain-HTTP port.

fail() {
  echo "FAIL: $*" >&2
  RESULT=1
}
RESULT=0

# --- 1) Precondition -----------------------------------------------------------------------
[ -d "$APP_PATH" ] || { echo "ABORT: $APP_PATH not found -- nothing to test against."; exit 2; }

# Pre-flight safety gate: never start this test with a leftover leaked helper/display already
# on the machine -- we could never attribute a post-test leak to THIS run.
if pgrep -fl vd_helper >/dev/null 2>&1; then
  echo "ABORT: vd_helper already running before the test started -- clean the machine first:"
  pgrep -fl vd_helper
  exit 2
fi

WORK="$(mktemp -d)"
BACKUP_CONF="$WORK/backup-sunshine.conf"
BACKUP_STATE="$WORK/backup-sunshine_state.json"
CLEANED_UP=""

cleanup() {
  [ -n "$CLEANED_UP" ] && return
  CLEANED_UP=1
  echo "--- cleanup: restoring live conf/state and daemon ---"

  if [ -f "$BACKUP_CONF" ]; then
    cp -f "$BACKUP_CONF" "$LIVE_CONF"
  fi
  if [ -f "$BACKUP_STATE" ]; then
    cp -f "$BACKUP_STATE" "$LIVE_STATE"
  fi

  launchctl kickstart -k "gui/$(id -u)/$DAEMON_LABEL" >/dev/null 2>&1 || true
  sleep 2

  # If a vd_helper leaked during the test, kill it and give WindowServer a moment to reap the
  # zombie display -- a killed helper alone does not remove the display from the online list
  # until something (a real sleep/wake, or a synthetic user-active assertion) nudges WindowServer.
  LEFTOVER="$(pgrep -f vd_helper || true)"
  if [ -n "$LEFTOVER" ]; then
    echo "cleanup: killing leaked vd_helper: $LEFTOVER"
    kill -TERM $LEFTOVER 2>/dev/null || true
    sleep 1
    kill -KILL $LEFTOVER 2>/dev/null || true
    caffeinate -u -t 3 >/dev/null 2>&1 || true
  fi

  osascript -e 'quit app "Skylight"' >/dev/null 2>&1 || true
  sleep 2

  rm -rf "$WORK"

  echo "--- cleanup: conf restored $( [ -f "$LIVE_CONF" ] && md5 -q "$LIVE_CONF" || echo MISSING )"
  echo "--- cleanup: state restored $( [ -f "$LIVE_STATE" ] && md5 -q "$LIVE_STATE" || echo MISSING )"
}
trap cleanup EXIT INT TERM

online_display_count() {
  cat > "$WORK/probe.swift" <<'SWIFT'
import CoreGraphics
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
print(count)
SWIFT
  swift "$WORK/probe.swift" 2>/dev/null
}

# --- 2) Backup -------------------------------------------------------------------------------
[ -f "$LIVE_CONF" ] || { echo "ABORT: $LIVE_CONF not found."; exit 2; }
[ -f "$LIVE_STATE" ] || { echo "ABORT: $LIVE_STATE not found."; exit 2; }
cp "$LIVE_CONF" "$BACKUP_CONF"
cp "$LIVE_STATE" "$BACKUP_STATE"
echo "backed up live conf ($(md5 -q "$LIVE_CONF")) and state ($(md5 -q "$LIVE_STATE")) to $WORK"

# --- 3a) Failure-trigger prep cmd: reuse if the live conf already has one, else inject one -----
# (default clean-machine path -- see file header).
if grep -qE '^global_prep_cmd' "$LIVE_CONF"; then
  STALE_LINE="$(grep -E '^global_prep_cmd' "$LIVE_CONF")"
  echo "live conf already has an uncommented global_prep_cmd -- reusing it as the failure trigger:"
  echo "  $STALE_LINE"
else
  MISSING_SCRIPT="$WORK/does-not-exist/arrange.sh"
  INJECTED_LINE="global_prep_cmd = [{\"do\":\"$MISSING_SCRIPT start\",\"undo\":\"$MISSING_SCRIPT stop\"}]"
  printf '\n%s\n' "$INJECTED_LINE" >> "$LIVE_CONF"
  echo "live conf has no uncommented global_prep_cmd (normal clean-install case) -- injected one"
  echo "pointing at a nonexistent script, so /launch fails the same way as the original defect:"
  echo "  $INJECTED_LINE"
fi

# --- 3b) Inject a trusted test client cert into state (preserve existing devices+uniqueid) ---
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/client.key" -out "$WORK/client.crt" \
  -days 2 -nodes -subj "/CN=SkylightLiveTest" 2>/dev/null

python3 - "$LIVE_STATE" "$WORK/client.crt" <<'PY'
import json, sys, uuid
state_path, cert_path = sys.argv[1], sys.argv[2]
with open(state_path) as f:
    data = json.load(f)
root = data.setdefault("root", {})
# boost::property_tree serializes an EMPTY child list as the string "" (measured live
# 2026-08-14 on a freshly regenerated state file) -- normalize "" / missing to a list.
devices = root.get("named_devices")
if not isinstance(devices, list):
    devices = []
    root["named_devices"] = devices
cert = open(cert_path).read()
devices.append({"name": "live-test", "cert": cert, "uuid": str(uuid.uuid4()).upper()})
with open(state_path, "w") as f:
    json.dump(data, f)
PY
echo "injected test client cert into $LIVE_STATE ($(python3 -c "import json; print(len(json.load(open('$LIVE_STATE'))['root']['named_devices']))") named_devices total)"

# --- 4) Reload: bring up the real app + daemon with our edited state -------------------------
# `open -a` alone starts BOTH the menu (Contents/MacOS/Skylight) and the daemon helper
# (Contents/Resources/Helpers/Skylight) together via SMAppService (confirmed live,
# 2026-08-14 13:2x -- `open -a` with nothing else already running produces both PIDs within
# ~1s). A `launchctl kickstart -k` issued a few seconds AFTER `open -a` force-restarts a daemon
# that may already have paired with the menu over XPC, and the menu's reconnect-to-a-fresh-
# daemon-instance path does not complete inside the capture gate's 10s window -- this is what
# produced the FIRST attempt's "No validated SkylightMenu peer attached" failure even with the
# real app running (see the discarded first run in the work log). So: ensure a clean quit
# first, then a single fresh `open -a`, no kickstart.
osascript -e 'quit app "Skylight"' >/dev/null 2>&1 || true
sleep 2
open -a "$APP_PATH"

READY=""
for i in $(seq 1 30); do
  if curl -s --max-time 2 "http://localhost:$HTTP_PORT/serverinfo" | grep -qi "<state>"; then
    READY=1
    break
  fi
  sleep 1
done
if [ -z "$READY" ]; then
  # Fallback only if the natural pairing above didn't come up at all within the window.
  echo "daemon not up after open -a alone -- trying one launchctl kickstart as a fallback"
  launchctl kickstart -k "gui/$(id -u)/$DAEMON_LABEL" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://localhost:$HTTP_PORT/serverinfo" | grep -qi "<state>"; then
      READY=1
      break
    fi
    sleep 1
  done
fi
[ -n "$READY" ] || { echo "ABORT: daemon never answered http://localhost:$HTTP_PORT/serverinfo within the reload window"; exit 2; }
echo "daemon serving on port $HTTPS_PORT"

# --- 5) Baseline -------------------------------------------------------------------------------
if pgrep -fl vd_helper >/dev/null 2>&1; then
  echo "ABORT: vd_helper already alive right after reload, before any /launch attempt:"
  pgrep -fl vd_helper
  exit 2
fi
BASELINE_DISPLAYS="$(online_display_count)"
echo "baseline online display count: $BASELINE_DISPLAYS"

# --- 6) /launch --------------------------------------------------------------------------------
RIKEY="$(openssl rand -hex 16)"
do_launch() {
  local appid="$1"
  curl -sk --cert "$WORK/client.crt" --key "$WORK/client.key" \
    "https://localhost:$HTTPS_PORT/launch?uniqueid=LIVETEST&appid=${appid}&rikey=${RIKEY}&rikeyid=1&localAudioPlayMode=0&mode=1920x1080x60"
}

RESP="$(do_launch 1)"
echo "launch response (appid=1): $RESP"

if echo "$RESP" | grep -q 'status_code="404"'; then
  echo "appid=1 unknown -- fetching /applist for a real app id"
  APPLIST="$(curl -sk --cert "$WORK/client.crt" --key "$WORK/client.key" "https://localhost:$HTTPS_PORT/applist")"
  REAL_APPID="$(python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.argv[1])
app = root.find('App')
print(app.find('ID').text if app is not None else '')
" "$APPLIST")"
  [ -n "$REAL_APPID" ] || { echo "ABORT: /applist returned no apps -- cannot exercise the launch path."; echo "$APPLIST"; exit 2; }
  echo "resolved real app id: $REAL_APPID"
  RESP="$(do_launch "$REAL_APPID")"
  echo "launch response (appid=$REAL_APPID): $RESP"
fi

if echo "$RESP" | grep -qi "Screen Recording permission not granted"; then
  echo "ABORT: installed app lacks Screen Recording TCC grant -- cannot exercise VD creation at all."
  exit 2
fi

# --- 7) Assertions (the contract) ---------------------------------------------------------------
echo "$RESP" | grep -q "<gamesession>1</gamesession>" && fail "launch unexpectedly succeeded"

sleep 5

LEAKED="$(pgrep -fl vd_helper || true)"
[ -z "$LEAKED" ] || fail "vd_helper leaked after aborted launch: $LEAKED"

# Wake the displays before comparing the online list: with the host's panels asleep,
# WindowServer defers removing even a correctly-released CGVirtualDisplay until the next
# display reconfiguration (measured live 2026-08-14: a properly ACK-released VD lingered
# "online" >90s asleep, cleared instantly on wake). The assertion stays discriminating:
# the original defect leaves vd_helper ALIVE, and a live helper's display survives the
# wake, while a released zombie clears on it.
caffeinate -u -t 3
sleep 4

AFTER_DISPLAYS="$(online_display_count)"
echo "post-abort online display count: $AFTER_DISPLAYS (baseline was $BASELINE_DISPLAYS)"
[ "$AFTER_DISPLAYS" = "$BASELINE_DISPLAYS" ] || {
  fail "online display list did not return to baseline ($BASELINE_DISPLAYS -> $AFTER_DISPLAYS): zombie WindowServer display leaked"
  system_profiler SPDisplaysDataType | grep -i "sunshine virtual" || true
}

curl -s --max-time 3 "http://localhost:$HTTP_PORT/serverinfo" | grep -qi "<state>" \
  || fail "daemon not serving after failed launch (not retryable)"

if [ "$RESULT" = "0" ]; then
  echo "PASS: aborted launch left no vd_helper, display list at baseline, daemon retryable"
else
  echo "--- one or more assertions FAILED, see FAIL lines above ---"
fi
exit "$RESULT"
