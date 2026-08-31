#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
linked="$tmp/linked-bin/hypertask"
mkdir -p "$(dirname "$linked")"
ln -s ../releases/hypertask "$linked"
HYPERTASK_INSTALL_PATH="$linked" "$repo_root/scripts/install-fleet.sh" "$artifact"
[[ -L "$linked" ]]
[[ $(readlink "$linked") == ../releases/hypertask ]]
cmp "$artifact" "$linked"
[[ $(stat -c '%a' "$link_target") == 755 ]]

printf 'fleet install tests passed\n'
