#!/bin/bash
# Sunshine global_prep_cmd hook — headless remote desktop via PRIMARY FLIP.
#   start: make the Sunshine virtual display the PRIMARY display (origin 0,0) at half-res HiDPI,
#          and move the physical monitor(s) aside to a secondary origin. Both stay ENABLED — we
#          only REPOSITION, never `enabled:false` (disabling corrupts the display link / needs a
#          reboot). This puts your menu bar, desktop icons, and newly-opened apps on the VD.
#   stop:  put the physical monitor back at origin (0,0) as primary (reposition only). macOS also
#          does this on its own when the VD is destroyed; this makes it deterministic.
set -u
DP="$(command -v displayplacer || true)"
[ -n "$DP" ] || DP=/opt/homebrew/bin/displayplacer
LOG=/tmp/sunshine_display.log
echo "=== $(date '+%H:%M:%S') action=${1:-start} (PRIMARY-FLIP) ===" >> "$LOG"

# displayplacer is a third-party tap, not a hard dependency of the OS — verify it's actually
# present once, up front, rather than letting every one of the ~10 call sites below fail silently
# into their existing `2>/dev/null`/`>> "$LOG" 2>&1` redirects (which would otherwise hide a
# missing binary from every normal place an operator looks).
if [ ! -x "$DP" ]; then
  echo "=== $(date '+%H:%M:%S') ERROR: displayplacer not found (checked PATH and $DP) — install via 'brew tap jakehilborn/jakehilborn && brew install displayplacer' (see https://github.com/jakehilborn/displayplacer); display arrange/restore is a no-op this run ===" >> "$LOG"
  exit 0
fi

# Physical-vs-virtual discrimination is DYNAMIC — no hardcoded monitor UUID. On any other Mac
# (different monitor, laptop built-in display, multiple externals, or a stranger's LG 27MP55 with
# a DIFFERENT persistent UUID — these are unique per physical panel) a hardcoded UUID would treat
# every real monitor as an unrecognized ghost. Investigated empirically (2026-07-17, standalone
# vd_helper runs on this machine) what `displayplacer list` actually exposes for a Sunshine VD:
#   - No name/vendor/product field surfaces at all — CGVirtualDisplayDescriptor's name/vendorID/
#     productID (vd_helper.m) never appear in displayplacer's text output.
#   - "Persistent screen id" and "Serial screen id" are BOTH freshly randomized by WindowServer on
#     every virtual-display creation (confirmed: recreating a VD with the SAME descriptor/serial
#     pool slot yields a DIFFERENT persistent UUID and serial each time) — not derivable, not
#     hardcodable, not pattern-matchable.
#   - "Type:" reads "27 inch external screen" for the VD too (desc.sizeInMillimeters mimics a 27"
#     panel) — identical to a real 27" monitor, no help.
#   - "Color Depth:" DOES reliably differ: every physical monitor observed here reports
#     color_depth:8 in its current-mode summary line; every VD created by vd_helper reports
#     color_depth:4 (this script's OWN primary-flip ARGS below already hardcodes `color_depth:4`
#     when placing the VD — i.e. the script already treats this as ground truth for "this is our
#     VD"). Treating color_depth:4 as "not a real monitor" is also safe in the ambiguous direction:
#     at worst it skips touching a stray/leaked virtual display exactly like a ghost — it can only
#     ever misclassify a would-be physical monitor as "not physical", never the reverse (mistaking
#     a real monitor for something to hide never happens from this test).
# The LIVE Sunshine VD's exact contextual id is separately and unambiguously known from
# /tmp/sunshine_vd_id (written by sunshine itself at VD-create time) — so a "ghost" is simply
# "has the color_depth:4 signature AND is not today's live VD".
# Re-verify after a WindowServer/displayplacer update with: displayplacer list

# --- awk parses below all accept an OPTIONAL trailing pre-captured `displayplacer list` output
# instead of invoking `$DP list` themselves. Every call site that omits it gets the exact old
# behavior (a fresh query, right there, every time) -- this is purely additive. Call sites that
# DO thread a captured snapshot through are ones where multiple parses in a row read the exact
# same, unmutated point-in-time state; collapsing those into one shared capture removes redundant
# `$DP list` invocations (~20ms each) without changing what is queried, in what order, or the
# result (latency fix; see arrange_displays.sh history / Skylight latency trace).

# Contextual ids of REAL physical displays: every display whose current-mode "Color Depth:" is
# NOT 4 (see discriminator note above). Returns as many ids as are actually connected — the
# start-case ARGS-building loop and the stop-case restore loop below both already iterate over
# this list, so multi-monitor machines are handled the same way a single-monitor machine is.
# $1 (optional): pre-captured `displayplacer list` output.
phys_ctx_ids() {
  local list="${1:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk '
    /Contextual screen id:/ {ctx=$NF; depth=""}
    /Color Depth:/ {if (depth=="") depth=$NF}
    /^$/ {if (ctx!="" && depth!="4") print ctx; ctx=""}
    END {if (ctx!="" && depth!="4") print ctx}'
}

# Contextual ids of enabled displays that carry the VD signature (color_depth:4) and are NOT the
# given live VD id — i.e. leaked/stray virtual displays from a torn-down session (or another app's
# virtual display), never a real monitor (see discriminator note above).
# $1: VD id to exclude (may be empty). $2 (optional): pre-captured `displayplacer list` output.
ghost_ctx_ids() {
  local vdid="${1:-}"
  local list="${2:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk -v vd="$vdid" '
    /Contextual screen id:/ {ctx=$NF; depth=""; en=1}
    /Color Depth:/ {if (depth=="") depth=$NF}
    /Enabled:/ {en=($2=="true")}
    /^$/ {if (ctx!="" && en && depth=="4" && ctx!=vd) print ctx; ctx=""}
    END {if (ctx!="" && en && depth=="4" && ctx!=vd) print ctx}'
}

# Current mode ("res:.. hz:.. color_depth:.. scaling:..") of a contextual display id.
# $1: contextual id. $2 (optional): pre-captured `displayplacer list` output.
disp_mode() {
  local id="$1"
  local list="${2:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk -v id="$id" '
    $0 ~ ("Contextual screen id: " id "$") {inblk=1; next}
    inblk && /Contextual screen id:/ {inblk=0}
    inblk && /Resolution:/  {r=$2}
    inblk && /Hertz:/       {hz=$2}
    inblk && /Color Depth:/ {cd=$NF}
    inblk && /Scaling:/     {sc=$2}
    END {if (r!="") printf "res:%s hz:%s color_depth:%s scaling:%s", r, hz, cd, sc}
  '
}

# Enabled state ("true"/"false") of a contextual display id. Extracted from the inline awk that
# used to be duplicated at both the start-case attempt loop and the stop-case physical lookup
# (same logic, same result, now shared) so both can also take a pre-captured snapshot.
# $1: contextual id. $2 (optional): pre-captured `displayplacer list` output.
disp_enabled() {
  local id="$1"
  local list="${2:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk -v id="$id" '
    $0 ~ ("Contextual screen id: " id "$") {f=1; next}
    f && /Contextual screen id:/ {exit}
    f && /Enabled:/ {print $2; exit}'
}

# $1: contextual id. $2 (optional): pre-captured `displayplacer list` output.
vd_res() {
  local id="$1"
  local list="${2:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk -v id="$id" '$0 ~ ("Contextual screen id: "id"$"){f=1} f&&/Resolution:/{print $2; exit}'
}

# $1 (optional): pre-captured `displayplacer list` output.
main_ctx() {
  local list="${1:-$("$DP" list 2>/dev/null)}"
  printf '%s\n' "$list" | awk '/Contextual screen id:/{c=$NF} /main display/{print c; exit}'
}

# Wake sleeping displays BEFORE any displayplacer call. Sunshine runs this hook
# (global_prep_cmd) BEFORE capture init, so the in-app display wake (display.mm) fires
# too late to protect this script: displayplacer against a sleeping/waking display
# yields "Error altering enabled/disabled config" and can corrupt the WindowServer
# display link (black VD until sleep/wake or monitor power-cycle — bitten 2026-07-10).
# No script-visible awake-detector exists on Apple Silicon (IODisplayWrangler is gone,
# DCP power states don't change with display sleep), so wake SYNCHRONOUSLY: foreground
# caffeinate -u declares user activity (same IOKit wake the app uses) and blocks for
# -t seconds, guaranteeing the wake transition has begun; the extra sleep lets it land.
# Flat ~2.5s per connect — the price of never racing displayplacer against a waking GPU.
# NOT touched by the list-invocation collapse below (load-bearing anti-corruption wait).
wake_displays() {
  /usr/bin/caffeinate -u -t 2 2>/dev/null
  sleep 0.5
}

case "${1:-start}" in
  start)
    wake_displays
    VD_ID=""
    for _ in $(seq 1 20); do
      VD_ID=$(cat /tmp/sunshine_vd_id 2>/dev/null)
      [ -n "$VD_ID" ] && [ "$VD_ID" != "0" ] && break
      sleep 0.25
    done
    [ -z "$VD_ID" ] || [ "$VD_ID" = "0" ] && { echo "no VD; skip" >> "$LOG"; exit 0; }

    # Ghost cure: a leaked VD from a previous session wedges WindowServer and the new VD
    # renders BLACK. A display sleep/wake cycle forces re-enumeration and clears ghosts
    # (the live VD and the session survive it — verified 2026-07-10). Only runs when a
    # ghost is actually detected, so the ~6s cost is paid only on the bad path.
    GHOSTS=$(ghost_ctx_ids "$VD_ID")
    if [ -n "$GHOSTS" ]; then
      echo "ghost display(s) detected [$(echo $GHOSTS | tr '\n' ' ')] — running sleep/wake cure" >> "$LOG"
      pmset displaysleepnow
      sleep 3
      /usr/bin/caffeinate -u -t 2 2>/dev/null
      sleep 2
      echo "cure done; ghosts now: [$(ghost_ctx_ids "$VD_ID" | tr '\n' ' ')]" >> "$LOG"
    fi

    # The primary flip MUST be one displayplacer transaction containing the VD (scaled,
    # at origin) AND every enabled KNOWN physical (moved aside): two displays cannot both
    # hold (0,0), so a VD-only command can never take main away from an awake physical
    # (deadlocked here 2026-07-10: 6 failed attempts, main stayed on the LG). The original
    # corruption came from including POWERED-OFF/GHOST displays in the transaction — so the
    # participant list is now: VD + enabled known-physicals ONLY. Ghosts and dark monitors
    # are never touched.
    # Native VD resolution is captured ONCE before the loop: re-reading it per attempt
    # returned the already-scaled mode after attempt 1 and re-halved the target (720x450).
    W=""; H=""
    for _ in $(seq 1 10); do
      VD_R=$(vd_res "$VD_ID"); W=${VD_R%x*}; H=${VD_R#*x}
      [ -n "$W" ] && [ "$W" -gt 0 ] 2>/dev/null && break
      sleep 0.3
    done
    [ -z "$W" ] || [ "$W" -le 0 ] 2>/dev/null && { echo "VD ${VD_ID} res never readable; abort arrange" >> "$LOG"; exit 0; }
    HW=$((W/2)); HH=$((H/2))

    APPLIED=""
    for attempt in 1 2 3 4 5 6; do
      # ONE captured snapshot for everything this iteration reads BEFORE the mutating
      # displayplacer call below: phys_ctx_ids, each physical's Enabled state, and its current
      # mode (previously 3 separate "$DP list" invocations, ~60ms). All three reads reflect the
      # exact same pre-mutation instant, so sharing one capture is equivalent, not approximate.
      # Re-captured fresh at the TOP of every iteration (never reused across iterations) because
      # the previous iteration's mutation changes this state.
      PRE_LIST=$("$DP" list 2>/dev/null)
      ARGS=("id:${VD_ID} res:${HW}x${HH} hz:60 color_depth:4 scaling:on origin:(0,0) degree:0")
      for p in $(phys_ctx_ids "$PRE_LIST"); do
        EN=$(disp_enabled "$p" "$PRE_LIST")
        if [ "$EN" = "true" ]; then
          M=$(disp_mode "$p" "$PRE_LIST")
          [ -n "$M" ] && ARGS+=("id:${p} ${M} origin:(${HW},0) degree:0")
        fi
      done
      "$DP" "${ARGS[@]}" >> "$LOG" 2>&1
      # ONE captured POST-mutation snapshot for both verification reads (disp_mode + main_ctx;
      # previously 2 separate "$DP list" invocations). Deliberately a fresh capture, never reused
      # from PRE_LIST above -- the whole point of this check is to observe state AFTER the
      # mutation just applied.
      POST_LIST=$("$DP" list 2>/dev/null)
      VD_M=$(disp_mode "$VD_ID" "$POST_LIST"); MC=$(main_ctx "$POST_LIST")
      echo "attempt $attempt: VD ${VD_ID} target ${HW}x${HH}@2x (+$((${#ARGS[@]}-1)) physicals); applied [${VD_M}]; main is now ${MC}" >> "$LOG"
      if [ "$MC" = "$VD_ID" ] && printf '%s' "$VD_M" | grep -q "res:${HW}x${HH}" && printf '%s' "$VD_M" | grep -q "scaling:on"; then
        APPLIED=1
        break
      fi
      sleep 0.4
    done
    [ -z "$APPLIED" ] && echo "WARNING: VD flip never verified (unscaled or not main) after 6 attempts" >> "$LOG"
    ;;

  stop)
    # Reposition the remaining physical back to primary at (0,0) — but ONLY if it is ENABLED
    # (powered on). When headless (the physical monitor is off => displayplacer reports it
    # Enabled:false), we must NOT run displayplacer against it: configuring a powered-off
    # display fails ("Error altering enabled/disabled config") and corrupts the display link,
    # which orphans the virtual display and black-screens the next connect. macOS already
    # reverts to the physical on its own when the VD is destroyed, so a no-op is correct here.
    # ONLY consider real physical displays (see phys_ctx_ids discriminator note near the top of
    # this file). The old "first Enabled:true display" heuristic picked up ghost displays when
    # headless (LG off) and displayplacer-mutated a dying/leaked VD mid-teardown — the
    # WindowServer corruption that black-screened the next connect (bitten 2026-07-10, display
    # 65 "(AirPlay)"). phys_ctx_ids may now return more than one candidate on a multi-monitor
    # machine; this loop iterates all of them and stops at the first ENABLED one, same as before.
    #
    # ONE captured snapshot for phys_ctx_ids + each candidate's Enabled state + its mode
    # (previously up to 1 + N + 1 separate "$DP list" invocations, N = known physicals).
    # Nothing mutates between these reads, so sharing one capture is equivalent.
    STOP_LIST=$("$DP" list 2>/dev/null)
    P=""
    for c in $(phys_ctx_ids "$STOP_LIST"); do
      EN=$(disp_enabled "$c" "$STOP_LIST")
      [ "$EN" = "true" ] && { P="$c"; break; }
    done
    if [ -n "$P" ]; then
      M=$(disp_mode "$P" "$STOP_LIST")
      [ -n "$M" ] && "$DP" "id:${P} ${M} origin:(0,0) degree:0" >> "$LOG" 2>&1
      echo "stop: enabled physical ${P} -> primary (0,0)" >> "$LOG"
    else
      echo "stop: no enabled KNOWN physical (headless or ghost-only) — skip; macOS reverts on VD destroy" >> "$LOG"
    fi
    ;;
esac
exit 0
