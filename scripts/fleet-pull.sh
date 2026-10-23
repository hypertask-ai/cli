#!/usr/bin/env bash
set -euo pipefail

stage='initialize'
work=''
committed=false
targets=()
backups=()
fail() {
  printf 'fleet pull: %s failed\n' "$stage" >&2
  exit 1
}
cleanup() {
  local status=$? i
  trap - ERR
  if [[ "$committed" == false ]]; then
    for ((i=${#targets[@]}-1; i>=0; i--)); do
      if [[ -n "${backups[i]}" ]]; then
        if ! mv -f "${backups[i]}" "${targets[i]}"; then
          printf 'fleet pull: rollback failed; backup retained at %s\n' "${backups[i]}" >&2
          status=1
        fi
      else
        rm -f "${targets[i]}" || status=1
      fi
    done
  else
    for i in "${backups[@]}"; do
      [[ -z "$i" ]] || rm -f "$i" || true
    done
  fi
  [[ -z "$work" ]] || rm -rf "$work" || true
  exit "$status"
}
trap fail ERR
trap cleanup EXIT
trap 'stage=interrupted; fail' HUP INT TERM

state="$HOME/.local/state/hypertask-cli"
destination=${HYPERTASK_INSTALL_PATH:-"$HOME/.local/bin/hypertask"}
installer=${FLEET_INSTALLER:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-fleet.sh"}
api=${FLEET_PULL_API:-https://api.github.com/repos/hypertask-ai/cli/releases/latest}
base=${FLEET_PULL_BASE:-https://github.com/hypertask-ai/cli/releases/download}
mkdir -p "$state"
exec 9>"$state/pull.lock"
stage='another pull is running'
flock -n 9 || fail

stage='read latest release'
work=$(mktemp -d)
curl -fsSL --connect-timeout 10 --max-time 60 "$api" -o "$work/release.json" 2>/dev/null
if ! tag=$(jq -er '.tag_name | strings | select(test("\\Av[0-9]+[.][0-9]+[.][0-9]+\\z"))' "$work/release.json" 2>/dev/null) || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  stage='invalid release tag'
  fail
fi
if [[ -x "$destination" && -f "$state/installed-tag" && -f "$state/installed-sha256" ]] \
  && [[ $(cat "$state/installed-tag") == "$tag" ]] \
  && [[ $(sha256sum "$destination" | awk '{print $1}') == "$(cat "$state/installed-sha256")" ]]; then
  printf 'up to date %s\n' "$tag"
  exit 0
fi

stage='download release'
asset=hypertask-linux-x86_64
curl -fsSL --connect-timeout 10 --max-time 120 "${base%/}/$tag/$asset" -o "$work/$asset" 2>/dev/null
curl -fsSL --connect-timeout 10 --max-time 60 "${base%/}/$tag/checksums.txt" -o "$work/checksums.txt" 2>/dev/null
stage='verify release checksum'
# Select only the exact asset name, rejecting duplicates and malformed hashes.
awk -v asset="$asset" '
  $2 == asset || $2 == "*" asset {
    count++
    if ($0 !~ /^[0-9a-fA-F]+ [ *]/ || length($1) != 64 || NF != 2) bad=1
    print
  }
  END { if (count != 1 || bad) exit 1 }
' "$work/checksums.txt" > "$work/asset.sha256"
(cd "$work" && sha256sum --check --strict asset.sha256 >/dev/null 2>&1)
chmod 755 "$work/$asset"
expected="hypertask ${tag#v} (zig)"
stage='verify release version'
version=$(cd "$work" && timeout 10 "./$asset" --version 2>/dev/null)
[[ "$version" == "$expected" ]] || fail
hash=$(sha256sum "$work/$asset" | awk '{print $1}')

# The existing installer can update PATH and npm copies too. Snapshot their
# resolved targets beside each file so a later failure can roll them back.
snapshot() {
  local target backup='' existing
  target=$(realpath -m "$1") || return 1
  for existing in "${targets[@]}"; do
    [[ "$existing" != "$target" ]] || return 0
  done
  mkdir -p "$(dirname "$target")" || return 1
  if [[ -e "$target" ]]; then
    backup=$(mktemp "${target}.rollback.XXXXXX") || return 1
    if ! cp -p "$target" "$backup"; then
      rm -f "$backup"
      return 1
    fi
  fi
  targets+=("$target")
  backups+=("$backup")
}
stage='prepare installation'
snapshot "$destination"
if path_ht=$(command -v hypertask 2>/dev/null); then
  snapshot "$path_ht"
fi
for other in "$HOME/.npm-global/bin/hypertask" "$HOME/.npm-global/lib/node_modules/@hypertask/hypertask_cli/bin/hypertask.exe"; do
  if [[ -e "$other" || -L "$other" ]]; then
    snapshot "$other"
  fi
done
snapshot "$state/installed-tag"
snapshot "$state/installed-sha256"
# Include each temporary marker in cleanup as soon as it is created.
tag_tmp=$(mktemp "$state/installed-tag.XXXXXX")
targets+=("$tag_tmp")
backups+=('')
hash_tmp=$(mktemp "$state/installed-sha256.XXXXXX")
targets+=("$hash_tmp")
backups+=('')
printf '%s\n' "$tag" > "$tag_tmp"
printf '%s\n' "$hash" > "$hash_tmp"
stage='install release'
bash "$installer" "$work/$asset" >"$work/install.log" 2>&1
stage='verify installed release'
cmp -s "$work/$asset" "$destination"
version=$(timeout 10 "$destination" --version 2>/dev/null)
[[ "$version" == "$expected" ]] || fail
stage='record installed release'
mv -f "$hash_tmp" "$state/installed-sha256"
mv -f "$tag_tmp" "$state/installed-tag"
committed=true
printf 'installed %s\n' "$tag"
