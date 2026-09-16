#!/usr/bin/env bash
set -euo pipefail

artifact=${1:-zig-out/bin/hypertask}
destination=${HYPERTASK_INSTALL_PATH:-"$HOME/.local/bin/hypertask"}

if [[ ! -x "$artifact" ]]; then
  printf 'build artifact is missing or not executable: %s\n' "$artifact" >&2
  exit 1
fi

staged_files=()
cleanup() {
  rm -f "${staged_files[@]:-}"
}
trap cleanup EXIT

# Write the artifact over dest. If dest is a symlink (the npm shim), replace
# the target and leave the link in place so PATH keeps working.
install_one() {
  local dest=$1
  local install_target=$dest
  mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" ]]; then
    install_target=$(realpath -m "$dest")
    mkdir -p "$(dirname "$install_target")"
  fi

  local staged
  staged=$(mktemp "${install_target}.tmp.XXXXXX")
  staged_files+=("$staged")
  install -m 755 "$artifact" "$staged"
  mv -f "$staged" "$install_target"
  cmp "$artifact" "$dest"
}

install_one "$destination"

# ht-product-bot and the worker units run `hypertask` off PATH. A fleet
# install that only wrote ~/.local/bin left the older npm binary first on
# those PATHs, so empty --assignee still failed after the code had shipped.
path_hypertask=$(command -v hypertask || true)
if [[ -n "$path_hypertask" ]]; then
  dest_real=$(realpath -m "$destination")
  path_real=$(realpath -m "$path_hypertask")
  if [[ "$path_real" != "$dest_real" ]]; then
    install_one "$path_hypertask"
  fi
fi
