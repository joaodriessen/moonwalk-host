#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macho-dependencies.sh
source "$DIR/macho-dependencies.sh"

[ "$#" -ge 2 ] || { echo "Usage: $0 APP MACHO [MACHO ...]" >&2; exit 64; }
APP="$1"
shift
[ -d "$APP/Contents" ] || { echo "ERROR: invalid app bundle: $APP" >&2; exit 1; }

queue=("$@")
seen=""
while [ "${#queue[@]}" -gt 0 ]; do
  consumer="${queue[0]}"
  queue=("${queue[@]:1}")
  is_macho_file "$consumer" || { echo "ERROR: not a Mach-O file: $consumer" >&2; exit 1; }
  case "\n$seen\n" in *"\n$consumer\n"*) continue ;; esac
  seen="${seen}${seen:+$'\n'}$consumer"

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    is_system_dependency "$dependency" && continue
    source_path="$(resolve_dependency "$APP" "$consumer" "$dependency")" || {
      echo "ERROR: unresolved dependency $dependency in $consumer" >&2
      exit 1
    }
    staged="$(copy_dependency_into_frameworks "$APP" "$source_path")"
    staged_real="$(cd "$(dirname "$staged")" && pwd -P)/$(basename "$staged")"
    install_name_tool -change "$dependency" "@rpath/$(basename "$staged")" "$consumer"
    if is_macho_file "$staged_real"; then
      install_name_tool -id "@rpath/$(basename "$staged")" "$staged_real" 2>/dev/null || true
      queue+=("$staged_real")
    fi
  done < <(list_macho_dependencies "$consumer")

  codesign --remove-signature "$consumer" 2>/dev/null || true
done

for root in "$@"; do
  case "$root" in
    "$APP/Contents/Resources/Helpers/"*) rpath='@executable_path/../../Frameworks' ;;
    "$APP/Contents/MacOS/"*) rpath='@executable_path/../Frameworks' ;;
    *) echo "ERROR: Mach-O root is outside supported app locations: $root" >&2; exit 1 ;;
  esac
  if ! otool -l "$root" | grep -A2 LC_RPATH | grep -Fq "path $rpath "; then
    install_name_tool -add_rpath "$rpath" "$root"
  fi
done

echo "Bundled Mach-O dependencies into $APP/Contents/Frameworks"
