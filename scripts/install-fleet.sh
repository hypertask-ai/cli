#!/usr/bin/env bash
set -euo pipefail

artifact=${1:-zig-out/bin/hypertask}
destination=${HYPERTASK_INSTALL_PATH:-"$HOME/.local/bin/hypertask"}

if [[ ! -x "$artifact" ]]; then
  printf 'build artifact is missing or not executable: %s\n' "$artifact" >&2
  exit 1
fi

install_one() {
  local dest=$1
  mkdir -p "$(dirname "$dest")"
  local install_target=$dest
  if [[ -L "$dest" ]]; then
    install_target=$(realpath -m "$dest")
    mkdir -p "$(dirname "$install_target")"
  fi
  local staged
  staged=$(mktemp "${install_target}.tmp.XXXXXX")
  install -m 755 "$artifact" "$staged"
  if ! mv -f "$staged" "$install_target"; then
    rm -f "$staged"
    return 1
  fi
  cmp "$artifact" "$dest"
}

install_one "$destination"

# Replace another hypertask path when it exists and is not the destination.
# Fleet jobs often have a stripped PATH, so command -v is not enough:
# ~/.npm-global/bin/hypertask still wins on login PATH (HTPR-6475).
dest_real=$(realpath -m "$destination")
replace_if_other() {
  local other=$1
  [[ -e "$other" || -L "$other" ]] || return 0
  local other_real
  other_real=$(realpath -m "$other")
  if [[ "$other_real" != "$dest_real" ]]; then
    install_one "$other"
  fi
}

if path_hypertask=$(command -v hypertask 2>/dev/null); then
  replace_if_other "$path_hypertask"
fi
replace_if_other "$HOME/.npm-global/bin/hypertask"
replace_if_other "$HOME/.npm-global/lib/node_modules/@hypertask/hypertask_cli/bin/hypertask.exe"
