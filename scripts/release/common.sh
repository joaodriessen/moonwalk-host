#!/bin/bash

release_repo_root() {
  local common_dir
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$common_dir/../.." && pwd
}

release_die() {
  echo "ERROR: $*" >&2
  return 1
}

release_app_digest() {
  local app="$1"
  [ -d "$app/Contents" ] || { release_die "invalid app for digest: $app"; return 1; }
  (
    cd "$app" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -L "$path" ]; then
        printf 'link %s %s\n' "$path" "$(readlink "$path")"
      else
        shasum -a 256 "$path"
      fi
    done
  ) | shasum -a 256 | awk '{print $1}'
}

require_developer_id() {
  local identity="${1:-}"
  case "$identity" in
    "Developer ID Application: "*) ;;
    *) release_die "release signing requires a Developer ID Application identity"; return 1 ;;
  esac
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$identity\""; then
    release_die "Developer ID Application identity '$identity' is not installed with a usable private key"
    return 1
  fi
}

release_team_id() {
  local identity="${1:-}"
  local work signed details team_id
  require_developer_id "$identity" || return 1
  work="$(mktemp -d)" || return 1
  signed="$work/identity-probe"
  cp /usr/bin/true "$signed"
  if ! codesign -s "$identity" --force --options runtime --timestamp=none "$signed" >/dev/null 2>&1; then
    rm -rf "$work"
    release_die "identity '$identity' could not sign a test executable"
    return 1
  fi
  details="$(codesign -dvv "$signed" 2>&1)"
  rm -rf "$work"
  team_id="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=\([A-Z0-9]\{10\}\)$/\1/p' | head -1)"
  if [ -z "$team_id" ]; then
    release_die "identity '$identity' did not produce a ten-character Team Identifier"
    return 1
  fi
  printf '%s\n' "$team_id"
}

require_release_tools() {
  local tool
  for tool in codesign security hdiutil otool install_name_tool; do
    command -v "$tool" >/dev/null 2>&1 || {
      release_die "required release tool '$tool' was not found"
      return 1
    }
  done
  xcrun --find notarytool >/dev/null 2>&1 || {
    release_die "xcrun could not find notarytool"
    return 1
  }
  xcrun --find stapler >/dev/null 2>&1 || {
    release_die "xcrun could not find stapler"
    return 1
  }
}
