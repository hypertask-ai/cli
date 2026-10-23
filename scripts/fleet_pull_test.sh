#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Both HOME and PATH are isolated: the existing installer updates npm and PATH
# copies as well as HYPERTASK_INSTALL_PATH. No real fleet binary is reachable.
export HOME="$tmp/home"
export PATH="$tmp/bin:/usr/bin:/bin"
export HYPERTASK_INSTALL_PATH="$HOME/custom/hypertask"
export FLEET_PULL_API="file://$tmp/latest.json"
export FLEET_PULL_BASE="file://$tmp/releases"
export FLEET_INSTALLER="$repo_root/scripts/install-fleet.sh"
export TEST_LOG="$tmp/systemctl.log"
mkdir -p "$HOME/.npm-global/bin" "$tmp/bin" "$tmp/releases"
printf '#!/usr/bin/env bash\nprintf "old version\\n"\n' > "$tmp/bin/hypertask"
chmod 755 "$tmp/bin/hypertask"
cp "$tmp/bin/hypertask" "$HOME/npm-target"
ln -s "$HOME/npm-target" "$HOME/.npm-global/bin/hypertask"
asset=hypertask-linux-x86_64
state="$HOME/.local/state/hypertask-cli"
pull="$repo_root/scripts/fleet-pull.sh"

release() {
  local tag=$1 version=${2:-${1#v}}
  release_dir="$tmp/releases/$tag"
  mkdir -p "$release_dir"
  printf '{"tag_name":"%s"}\n' "$tag" > "$tmp/latest.json"
  printf '#!/usr/bin/env bash\nprintf "hypertask %s (zig)\\n"\n' "$version" > "$release_dir/$asset"
  (cd "$release_dir" && sha256sum "$asset" > checksums.txt)
}
run() {
  bash "$pull" > "$tmp/output" 2>&1
}
assert_unchanged_failure() {
  local message=$1 file i=0
  local files=("$HYPERTASK_INSTALL_PATH" "$tmp/bin/hypertask" "$HOME/npm-target" "$state/installed-tag" "$state/installed-sha256")
  for file in "${files[@]}"; do
    cp -p "$file" "$tmp/before.$i"
    i=$((i+1))
  done
  if run; then
    printf 'unexpected success: %s\n' "$message" >&2
    exit 1
  fi
  grep -Fxq "fleet pull: $message failed" "$tmp/output"
  [[ $(wc -l < "$tmp/output") == 1 ]]
  i=0
  for file in "${files[@]}"; do
    cmp "$file" "$tmp/before.$i"
    [[ $(stat -c '%a' "$file") == "$(stat -c '%a' "$tmp/before.$i")" ]]
    i=$((i+1))
  done
  [[ -L "$HOME/.npm-global/bin/hypertask" ]]
}

release v1.2.3
run
grep -Fxq 'installed v1.2.3' "$tmp/output"
cmp "$release_dir/$asset" "$HYPERTASK_INSTALL_PATH"
cmp "$release_dir/$asset" "$tmp/bin/hypertask"
cmp "$release_dir/$asset" "$HOME/npm-target"
[[ $(stat -c '%a' "$HYPERTASK_INSTALL_PATH") == 755 ]]
[[ $(cat "$state/installed-tag") == v1.2.3 ]]
[[ $(cat "$state/installed-sha256") == "$(sha256sum "$HYPERTASK_INSTALL_PATH" | awk '{print $1}')" ]]
printf 'ok fresh install and state\n'

# If either asset is requested, file:// returns an error.
mv "$release_dir" "$release_dir.saved"
run
grep -Fxq 'up to date v1.2.3' "$tmp/output"
mv "$release_dir.saved" "$release_dir"
printf 'ok up to date without asset downloads\n'

printf 'changed installed file\n' > "$HYPERTASK_INSTALL_PATH"
run
cmp "$release_dir/$asset" "$HYPERTASK_INSTALL_PATH"
printf 'ok changed installed file is repaired\n'

release v1.2.4
printf '# changed download\n' >> "$release_dir/$asset"
assert_unchanged_failure 'verify release checksum'
printf 'ok checksum mismatch preserves installed files\n'

release v1.2.4 9.9.9
assert_unchanged_failure 'verify release version'
printf 'ok wrong version preserves installed files\n'

for tag in '1.2.4' 'v1.2.4-rc1' '../v1.2.4'; do
  printf '{"tag_name":"%s"}\n' "$tag" > "$tmp/latest.json"
  assert_unchanged_failure 'invalid release tag'
done
printf '{"tag_name":"v1.2.4\\n"}\n' > "$tmp/latest.json"
assert_unchanged_failure 'invalid release tag'
printf 'ok malformed tags refused\n'

release v1.2.4
mv "$release_dir/$asset" "$tmp/saved-asset"
assert_unchanged_failure 'download release'
mv "$tmp/saved-asset" "$release_dir/$asset"
FLEET_PULL_API="file://$tmp/absent.json" assert_unchanged_failure 'read latest release'
printf 'ok unavailable release metadata and asset preserve installed files\n'
cp "$release_dir/checksums.txt" "$tmp/checksum"
cat "$tmp/checksum" >> "$release_dir/checksums.txt"
assert_unchanged_failure 'verify release checksum'
sed "s/$asset/${asset}.extra/" "$tmp/checksum" > "$release_dir/checksums.txt"
assert_unchanged_failure 'verify release checksum'
printf 'invalid  %s\n' "$asset" > "$release_dir/checksums.txt"
assert_unchanged_failure 'verify release checksum'
cp "$tmp/checksum" "$release_dir/checksums.txt"
printf 'ok duplicate, nonexact and malformed checksum entries refused\n'

exec 8>"$state/pull.lock"
flock -n 8
assert_unchanged_failure 'another pull is running'
flock -u 8
exec 8>&-
printf 'ok overlapping pull refused\n'

cat > "$tmp/failing-installer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
bash "$REAL_INSTALLER" "$1"
exit 1
SH
export REAL_INSTALLER="$FLEET_INSTALLER"
FLEET_INSTALLER="$tmp/failing-installer" assert_unchanged_failure 'install release'
printf 'ok installer failure rolls back all installed copies\n'

cat > "$tmp/wrong-installer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
bash "$REAL_INSTALLER" "$1"
printf 'wrong installed contents\n' > "$HYPERTASK_INSTALL_PATH"
SH
FLEET_INSTALLER="$tmp/wrong-installer" assert_unchanged_failure 'verify installed release'
printf 'ok post-install comparison failure rolls back\n'

# Fail after one state marker has moved to exercise state and binary rollback.
cat > "$tmp/bin/mv" <<'SH'
#!/usr/bin/env bash
if [[ ${FAIL_TAG_MOVE:-} == 1 && ${*: -1} == */installed-tag && $* != *rollback* ]]; then
  exit 1
fi
exec /usr/bin/mv "$@"
SH
chmod 755 "$tmp/bin/mv"
FAIL_TAG_MOVE=1 assert_unchanged_failure 'record installed release'
printf 'ok state-write failure rolls back markers and binaries\n'

# A version which depends on its install path passes download validation but
# fails the required installed --version check while remaining byte-identical.
cat > "$release_dir/$asset" <<'SH'
#!/usr/bin/env bash
if [[ "$0" == ./hypertask-linux-x86_64 || "$0" == */hypertask-linux-x86_64 ]]; then
  printf 'hypertask 1.2.4 (zig)\n'
else
  printf 'different installed version\n'
fi
SH
(cd "$release_dir" && sha256sum "$asset" > checksums.txt)
assert_unchanged_failure 'verify installed release'
printf 'ok installed version failure rolls back\n'

release v1.2.4
run
[[ $(cat "$state/installed-tag") == v1.2.4 ]]
printf 'ok valid release update after failures\n'

# A failed first install must remove newly created copies and state markers.
old_home=$HOME
export HOME="$tmp/failed-first-home"
old_destination=$HYPERTASK_INSTALL_PATH
export HYPERTASK_INSTALL_PATH="$HOME/custom/hypertask"
cp "$tmp/bin/hypertask" "$tmp/path-before-first-failure"
if FLEET_INSTALLER="$tmp/failing-installer" run; then
  printf 'unexpected successful first install\n' >&2
  exit 1
fi
[[ ! -e "$HYPERTASK_INSTALL_PATH" ]]
[[ ! -e "$HOME/.local/state/hypertask-cli/installed-tag" ]]
[[ ! -e "$HOME/.local/state/hypertask-cli/installed-sha256" ]]
cmp "$tmp/path-before-first-failure" "$tmp/bin/hypertask"
export HOME="$old_home" HYPERTASK_INSTALL_PATH="$old_destination"
printf 'ok failed first install removes new binaries and markers\n'

# Exercise the default destination and installer lookup without source checkout.
export HOME="$tmp/default-home"
unset HYPERTASK_INSTALL_PATH FLEET_INSTALLER
mkdir -p "$tmp/copied"
cp "$pull" "$repo_root/scripts/install-fleet.sh" "$tmp/copied/"
bash "$tmp/copied/fleet-pull.sh" > "$tmp/output" 2>&1
cmp "$release_dir/$asset" "$HOME/.local/bin/hypertask"
printf 'ok default destination and adjacent installer\n'

cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
SH
chmod 755 "$tmp/bin/systemctl"
export HOME="$tmp/timer-home"
bash "$repo_root/scripts/fleet-pull-install.sh" --dry-run > "$tmp/dry-run"
[[ ! -e "$HOME" && ! -e "$TEST_LOG" ]]
grep -Fq 'Would write' "$tmp/dry-run"
grep -Fq 'systemctl --user daemon-reload && systemctl --user enable --now hypertask-fleet-pull.timer' "$tmp/dry-run"
bash "$repo_root/scripts/fleet-pull-install.sh"
libexec="$HOME/.local/libexec/hypertask-fleet"
units="$HOME/.config/systemd/user"
cmp "$pull" "$libexec/fleet-pull.sh"
cmp "$repo_root/scripts/install-fleet.sh" "$libexec/install-fleet.sh"
[[ -x "$libexec/fleet-pull.sh" && -x "$libexec/install-fleet.sh" ]]
for line in Type=oneshot Nice=19 'ExecStart="%h/.local/libexec/hypertask-fleet/fleet-pull.sh"'; do
  grep -Fxq "$line" "$units/hypertask-fleet-pull.service"
done
for line in OnBootSec=2min OnUnitActiveSec=15min Persistent=true WantedBy=timers.target; do
  grep -Fxq "$line" "$units/hypertask-fleet-pull.timer"
done
printf '%s\n' '--user daemon-reload' '--user enable --now hypertask-fleet-pull.timer' > "$tmp/expected-systemctl"
cmp "$tmp/expected-systemctl" "$TEST_LOG"
printf 'ok timer setup with fake systemctl and side-effect-free dry run\n'

# Reuse the existing regression suite, with HOME and PATH still isolated.
bash "$repo_root/scripts/install_fleet_test.sh"
printf 'fleet pull tests passed\n'
