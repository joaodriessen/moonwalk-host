#!/bin/bash

is_system_dependency() {
  case "$1" in
    /System/Library/*|/usr/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_macho_file() {
  [ -f "$1" ] && file -b "$1" | grep -q 'Mach-O'
}

list_macho_dependencies() {
  otool -L "$1" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/'
}

resolve_dependency() {
  local app="$1" consumer="$2" dependency="$3" candidate
  case "$dependency" in
    @rpath/*)
      candidate="$app/Contents/Frameworks/${dependency#@rpath/}"
      ;;
    @loader_path/*)
      candidate="$(cd "$(dirname "$consumer")" && pwd)/${dependency#@loader_path/}"
      ;;
    @executable_path/*)
      candidate="$app/Contents/MacOS/${dependency#@executable_path/}"
      ;;
    /*)
      candidate="$dependency"
      ;;
    *)
      return 1
      ;;
  esac
  [ -e "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

copy_dependency_into_frameworks() {
  local app="$1" source="$2" frameworks destination source_hash destination_hash
  frameworks="$app/Contents/Frameworks"
  mkdir -p "$frameworks"

  if [ -L "$source" ]; then
    local target target_source
    target="$(readlink "$source")"
    case "$target" in
      /*) target_source="$target" ;;
      *) target_source="$(dirname "$source")/$target" ;;
    esac
    copy_dependency_into_frameworks "$app" "$target_source" >/dev/null
    destination="$frameworks/$(basename "$source")"
    if [ -e "$destination" ] && [ ! -L "$destination" ]; then
      echo "ERROR: dependency basename collision at $destination" >&2
      return 1
    fi
    [ -L "$destination" ] || ln -s "$(basename "$target")" "$destination"
    printf '%s\n' "$destination"
    return 0
  fi

  destination="$frameworks/$(basename "$source")"
  if [ -e "$destination" ]; then
    source_hash="$(shasum -a 256 "$source" | awk '{print $1}')"
    destination_hash="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [ "$source_hash" != "$destination_hash" ]; then
      echo "ERROR: dependency basename collision for $(basename "$source")" >&2
      return 1
    fi
  else
    cp -p "$source" "$destination"
  fi
  printf '%s\n' "$destination"
}
