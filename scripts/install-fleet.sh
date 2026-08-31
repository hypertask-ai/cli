#!/usr/bin/env bash
set -euo pipefail

artifact=${1:-zig-out/bin/hypertask}
destination=${HYPERTASK_INSTALL_PATH:-"$HOME/.local/bin/hypertask"}

if [[ ! -x "$artifact" ]]; then
  printf 'build artifact is missing or not executable: %s\n' "$artifact" >&2
  exit 1
fi

mkdir -p "$(dirname "$destination")"
install_target=$destination
if [[ -L "$destination" ]]; then
  link_target=$(readlink "$destination")
  if [[ "$link_target" = /* ]]; then
    install_target=$link_target
  else
    install_target=$(realpath -m "$(dirname "$destination")/$link_target")
  fi
  mkdir -p "$(dirname "$install_target")"
fi

staged=$(mktemp "${install_target}.tmp.XXXXXX")
trap 'rm -f "$staged"' EXIT
install -m 755 "$artifact" "$staged"
mv -f "$staged" "$install_target"
cmp "$artifact" "$destination"
