#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# install-fleet.sh also writes $HOME/.npm-global/bin/hypertask. Point HOME
# at the temp dir so a test never replaces the live wrapper (HTPR-6475).
export HOME="$tmp/home"
mkdir -p "$HOME"

artifact="$tmp/hypertask-build"
printf '#!/usr/bin/env bash\nprintf "fleet build\\n"\n' >"$artifact"
chmod 755 "$artifact"

regular="$tmp/bin/hypertask"
HYPERTASK_INSTALL_PATH="$regular" "$repo_root/scripts/install-fleet.sh" "$artifact"
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
HYPERTASK_INSTALL_PATH="$linked" "$repo_root/scripts/install-fleet.sh" "$artifact"
[[ -L "$linked" ]]
[[ $(readlink "$linked") == ../current/hypertask ]]
[[ -L "$intermediate" ]]
[[ $(readlink "$intermediate") == ../releases/hypertask ]]
cmp "$artifact" "$linked"
[[ $(stat -c '%a' "$link_target") == 755 ]]

# HTPR-6520: wrappers run `hypertask` from PATH. npm-global often wins over
# ~/.local/bin, so a fleet install that only writes the destination leaves
# agents on the old binary (`--assignee ""` still missing_field).
old_path_dir="$tmp/npm-global/bin"
mkdir -p "$old_path_dir"
old_path="$old_path_dir/hypertask"
printf 'old npm\n' >"$old_path"
chmod 755 "$old_path"
PATH="$old_path_dir:$PATH" HYPERTASK_INSTALL_PATH="$regular" "$repo_root/scripts/install-fleet.sh" "$artifact"
cmp "$artifact" "$regular"
cmp "$artifact" "$old_path"

# Same layout as ~/.npm-global/bin/hypertask -> .../hypertask.exe
npm_target="$tmp/npm-lib/hypertask.exe"
mkdir -p "$(dirname "$npm_target")"
printf 'old exe\n' >"$npm_target"
chmod 755 "$npm_target"
npm_link_dir="$tmp/npm-global-link/bin"
mkdir -p "$npm_link_dir"
ln -s "$npm_target" "$npm_link_dir/hypertask"
PATH="$npm_link_dir:$PATH" HYPERTASK_INSTALL_PATH="$regular" "$repo_root/scripts/install-fleet.sh" "$artifact"
[[ -L "$npm_link_dir/hypertask" ]]
cmp "$artifact" "$npm_target"

# HTPR-6475: fleet jobs often have a stripped PATH, so command -v misses
# ~/.npm-global/bin/hypertask. That file still wins on a login PATH.
stripped_home="$tmp/home-stripped"
mkdir -p "$stripped_home/.npm-global/bin"
printf 'old npm hidden\n' >"$stripped_home/.npm-global/bin/hypertask"
chmod 755 "$stripped_home/.npm-global/bin/hypertask"
PATH="/usr/bin:/bin" HOME="$stripped_home" HYPERTASK_INSTALL_PATH="$regular" \
  "$repo_root/scripts/install-fleet.sh" "$artifact"
cmp "$artifact" "$regular"
cmp "$artifact" "$stripped_home/.npm-global/bin/hypertask"

printf 'fleet install tests passed\n'
