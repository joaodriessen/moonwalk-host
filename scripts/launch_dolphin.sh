#!/bin/bash
# Launch Dolphin and move it to the Sunshine virtual display

open -a Dolphin
sleep 3

# Validate that a string is a plain integer (optional leading '-', digits only)
is_integer() {
    val="$1"
    case "$val" in
        -*) val="${val#-}" ;;
    esac
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Read virtual display ID written by Sunshine.
# /tmp/sunshine_vd_id is a fixed, world-writable-directory path, so harden the read:
# reject symlinks and files we don't own, and require the contents to look like a
# CGDirectDisplayID (plain non-negative integer) before trusting it.
VD_ID=""
VD_ID_FILE=/tmp/sunshine_vd_id
if [ -f "$VD_ID_FILE" ] && [ ! -L "$VD_ID_FILE" ] && [ -O "$VD_ID_FILE" ]; then
    VD_ID=$(cat "$VD_ID_FILE")
fi

if ! is_integer "$VD_ID"; then
    VD_ID=""
fi

if [ -z "$VD_ID" ] || [ "$VD_ID" = "0" ]; then
    echo "No virtual display active, Dolphin stays on current display"
    exit 0
fi

# Get the virtual display's origin coordinates
SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
GET_ORIGIN="$HOME/.local/share/lumen/get_display_origin"

if [ ! -x "$GET_ORIGIN" ]; then
    echo "get_display_origin not found at $GET_ORIGIN"
    exit 0
fi

BOUNDS=$($GET_ORIGIN "$VD_ID")
X=$(echo "$BOUNDS" | awk '{print $1}')
Y=$(echo "$BOUNDS" | awk '{print $2}')

if [ -z "$X" ] || [ -z "$Y" ]; then
    echo "Could not get virtual display bounds for ID $VD_ID"
    exit 0
fi

# X/Y come from get_display_origin's stdout and are spliced into an AppleScript
# string below; require they are plain integers before that happens.
if ! is_integer "$X" || ! is_integer "$Y"; then
    echo "Could not get virtual display bounds for ID $VD_ID"
    exit 0
fi

echo "Moving Dolphin to virtual display $VD_ID at ($X, $Y)"

# Move Dolphin window to the virtual display and make it fullscreen
osascript -e "tell application \"System Events\" to tell process \"Dolphin\" to set position of window 1 to {${X}, ${Y}}"
sleep 0.5
# Enter fullscreen
osascript -e 'tell application "System Events" to tell process "Dolphin" to keystroke "f" using {command down, shift down}'
