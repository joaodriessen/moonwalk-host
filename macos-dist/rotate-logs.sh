#!/bin/bash
# Bound Skylight's launchd stdout/stderr without restarting the long-running daemon. Each
# rotation copies the current contents to history, then truncates the active inode in place.
set -euo pipefail

LOG_DIR="${HOME}/.config/skylight"
MAX_BYTES=8388608

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --log-dir requires a value" >&2; exit 2; }
      LOG_DIR="$2"
      shift 2
      ;;
    --max-bytes)
      [ "$#" -ge 2 ] || { echo "ERROR: --max-bytes requires a value" >&2; exit 2; }
      MAX_BYTES="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--log-dir DIR] [--max-bytes N]" >&2
      exit 2
      ;;
  esac
done

case "$MAX_BYTES" in
  ''|*[!0-9]*|0)
    echo "ERROR: --max-bytes must be a positive integer" >&2
    exit 2
    ;;
esac

mkdir -p "$LOG_DIR"
LOCK_DIR="$LOG_DIR/.skylight-logrotate.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

rotate_one() {
  local active="$1" size
  [ -f "$active" ] || return 0
  size="$(stat -f%z "$active")"
  [ "$size" -gt "$MAX_BYTES" ] || return 0

  [ ! -e "$active.2" ] || mv -f "$active.2" "$active.3"
  [ ! -e "$active.1" ] || mv -f "$active.1" "$active.2"
  cp -p "$active" "$active.1"
  : > "$active"
}

rotate_one "$LOG_DIR/launchd.out.log"
rotate_one "$LOG_DIR/launchd.err.log"
