#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

artifact="$tmp/hypertask-build"
printf '#!/usr/bin/env bash\nprintf "fleet build\\n"\n' >"$artifact"
chmod 755 "$artifact"

# Never inherit the host PATH. A leaked `command -v hypertask` would overwrite
# the machine's real CLI during this test. Keep /usr/bin so `env bash` still
# finds the interpreter.
empty_path="$tmp/empty-path"
mkdir -p "$empty_path"
isolated_path="$empty_path:/usr/bin:/bin"

run_install() {
  local dest=$1
  shift
  PATH="${1:-$isolated_path}" HYPERTASK_INSTALL_PATH="$dest" \
    "$repo_root/scripts/install-fleet.sh" "$artifact"
}

regular="$tmp/bin/hypertask"
run_install "$regular"
cmp "$artifact" "$regular"
[[ $(stat -c '%a' "$regular") == 755 ]]

link_target="$tmp/releases/hypertask"
mkdir -p "$(dirname "$link_target")"
printf 'old build\n' >"$link_target"
intermediate="$tmp/current/hypertask"
mkdir -p "$(dirname "$intermediate")"
ln -s ../releases/hypertask "$intermediate"
linked="$tmp/linked-bin/hypertask"
mkdir -p "$(dirname "$linked")"
ln -s ../current/hypertask "$linked"
run_install "$linked"
[[ -L "$linked" ]]
[[ $(readlink "$linked") == ../current/hypertask ]]
[[ -L "$intermediate" ]]
[[ $(readlink "$intermediate") == ../releases/hypertask ]]
cmp "$artifact" "$linked"
[[ $(stat -c '%a' "$link_target") == 755 ]]

# PATH points at a different older binary. Fleet install must replace both.
path_bin="$tmp/npm-bin/hypertask"
mkdir -p "$(dirname "$path_bin")"
printf 'old npm\n' >"$path_bin"
chmod 755 "$path_bin"
path_dest="$tmp/local-bin/hypertask"
run_install "$path_dest" "$(dirname "$path_bin"):$isolated_path"
cmp "$artifact" "$path_dest"
cmp "$artifact" "$path_bin"
[[ $(stat -c '%a' "$path_bin") == 755 ]]

# PATH points at the npm symlink. Replace the target, keep the link.
npm_target="$tmp/npm-lib/hypertask.exe"
mkdir -p "$(dirname "$npm_target")" "$(dirname "$tmp/npm-shim/hypertask")"
printf 'old npm exe\n' >"$npm_target"
chmod 755 "$npm_target"
ln -s ../npm-lib/hypertask.exe "$tmp/npm-shim/hypertask"
shim_dest="$tmp/local-shim/hypertask"
run_install "$shim_dest" "$tmp/npm-shim:$isolated_path"
[[ -L "$tmp/npm-shim/hypertask" ]]
[[ $(readlink "$tmp/npm-shim/hypertask") == ../npm-lib/hypertask.exe ]]
cmp "$artifact" "$shim_dest"
cmp "$artifact" "$tmp/npm-shim/hypertask"
cmp "$artifact" "$npm_target"

printf 'fleet install tests passed\n'
