#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macho-dependencies.sh
source "$DIR/macho-dependencies.sh"

[ "$#" -ge 1 ] || { echo "Usage: $0 APP [BUILD_ROOT ...]" >&2; exit 64; }
APP="$1"
shift
[ -d "$APP/Contents" ] || { echo "ERROR: invalid app bundle: $APP" >&2; exit 1; }
CONTENTS="$(realpath "$APP/Contents")"
for root in "$@"; do
  case "$root" in
    /*/*) ;;
    *) echo "ERROR: build roots must be absolute directory paths" >&2; exit 64 ;;
  esac
done

failures=0
machos=0
while IFS= read -r -d '' candidate; do
  is_macho_file "$candidate" || continue
  machos=$((machos + 1))

  for root in "$@"; do
    if LC_ALL=C grep -aFq -- "${root%/}/" "$candidate"; then
      echo "ERROR: embedded build path in ${candidate#"$APP"/}" >&2
      failures=$((failures + 1))
      break
    elif [ "$?" -ne 1 ]; then
      echo "ERROR: could not check for embedded build paths in ${candidate#"$APP"/}" >&2
      failures=$((failures + 1))
      break
    fi
  done

  if ! lipo -archs "$candidate" | tr ' ' '\n' | grep -qx arm64; then
    echo "ERROR: missing arm64 architecture: $candidate" >&2
    failures=$((failures + 1))
  fi

  if ! minos="$(vtool -arch arm64 -show-build "$candidate" 2>/dev/null |
    awk '$1 == "minos" && !found { print $2; found = 1 }')" ||
    ! awk -v version="$minos" 'BEGIN {
      if (version !~ /^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$/) exit 1;
      split(version, v, ".");
      exit !(v[1]+0 < 14 || (v[1]+0 == 14 && v[2]+0 == 0 && v[3]+0 == 0));
    }'; then
    echo "ERROR: deployment target exceeds macOS 14.0 (minos ${minos:-unknown}): $candidate" >&2
    failures=$((failures + 1))
  fi

  if ! dependencies="$(list_macho_dependencies "$candidate")"; then
    echo "ERROR: could not read dependencies in $candidate" >&2
    failures=$((failures + 1))
    continue
  fi
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    is_system_dependency "$dependency" && continue
    if ! resolved="$(resolve_dependency "$APP" "$candidate" "$dependency")" ||
       ! resolved="$(realpath "$resolved")"; then
      echo "ERROR: unresolved or non-portable dependency $dependency in $candidate" >&2
      failures=$((failures + 1))
      continue
    fi
    case "$resolved" in
      "$CONTENTS/"*) ;;
      *) echo "ERROR: dependency escapes app bundle: $dependency in $candidate" >&2; failures=$((failures + 1)) ;;
    esac
  done <<< "$dependencies"
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
