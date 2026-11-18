#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macho-dependencies.sh
source "$DIR/macho-dependencies.sh"

[ "$#" -eq 1 ] || { echo "Usage: $0 APP" >&2; exit 64; }
APP="$1"
[ -d "$APP/Contents" ] || { echo "ERROR: invalid app bundle: $APP" >&2; exit 1; }

failures=0
machos=0
while IFS= read -r -d '' candidate; do
  is_macho_file "$candidate" || continue
  machos=$((machos + 1))

  if ! lipo -archs "$candidate" | tr ' ' '\n' | grep -qx arm64; then
    echo "ERROR: missing arm64 architecture: $candidate" >&2
    failures=$((failures + 1))
  fi

  minos="$(vtool -show-build "$candidate" 2>/dev/null | awk '/minos/{print $2; exit}')"
  if [ -z "$minos" ] || ! awk -v version="$minos" 'BEGIN { split(version,v,"."); exit !((v[1]+0)<14 || ((v[1]+0)==14 && (v[2]+0)==0)) }'; then
    echo "ERROR: deployment target exceeds macOS 14.0 (minos ${minos:-unknown}): $candidate" >&2
    failures=$((failures + 1))
  fi

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    is_system_dependency "$dependency" && continue
    if ! resolved="$(resolve_dependency "$APP" "$candidate" "$dependency")"; then
      echo "ERROR: unresolved or non-portable dependency $dependency in $candidate" >&2
      failures=$((failures + 1))
      continue
    fi
    case "$resolved" in
      "$APP/Contents/"*) ;;
      *) echo "ERROR: dependency escapes app bundle: $dependency in $candidate" >&2; failures=$((failures + 1)) ;;
    esac
  done < <(list_macho_dependencies "$candidate")
done < <(find "$APP/Contents" -type f -print0)

[ "$machos" -gt 0 ] || { echo "ERROR: app contains no Mach-O files" >&2; exit 1; }
if find "$APP/Contents/Frameworks" -type f -print -quit 2>/dev/null | grep -q .; then
  [ -f "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" ] || {
    echo "ERROR: bundled libraries have no staged third-party notices" >&2
    failures=$((failures + 1))
  }
fi
[ "$failures" -eq 0 ] || exit 1
echo "PASS: $machos Mach-O files are portable, arm64, and macOS 14 compatible"
