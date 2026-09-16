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

# Wrappers (`ht-product-bot`, `ht-dev-2`) run `hypertask` from PATH.
# npm-global often sits ahead of ~/.local/bin, so a destination-only
# install leaves agents on a stale binary. Replace that PATH winner too.
if path_hypertask=$(command -v hypertask 2>/dev/null); then
  dest_real=$(realpath -m "$destination")
  path_real=$(realpath -m "$path_hypertask")
  if [[ "$path_real" != "$dest_real" ]]; then
    install_one "$path_hypertask"
  fi
fi
