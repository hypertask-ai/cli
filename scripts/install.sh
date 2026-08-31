#!/bin/sh
set -eu

repository=${HYPERTASK_CLI_RELEASE_ROOT:-https://github.com/hypertask-ai/cli/releases}
version=${HYPERTASK_CLI_VERSION:-latest}
install_dir=${HYPERTASK_INSTALL_DIR:-"$HOME/.local/bin"}

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) echo "Hypertask CLI supports Linux and macOS through this installer." >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) architecture=x86_64 ;;
  arm64|aarch64) architecture=aarch64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

asset="hypertask-$platform-$architecture"
if [ "$version" = latest ]; then
  download_base="$repository/latest/download"
else
  case "$version" in v*) tag=$version ;; *) tag="v$version" ;; esac
  download_base="$repository/download/$tag"
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
curl -fsSL "$download_base/$asset" -o "$work_dir/$asset"
curl -fsSL "$download_base/checksums.txt" -o "$work_dir/checksums.txt"
expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$work_dir/checksums.txt")
[ -n "$expected" ] || { echo "No checksum found for $asset." >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work_dir/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$work_dir/$asset" | awk '{ print $1 }')
else
  echo "A SHA-256 checksum tool is required." >&2
  exit 1
fi
[ "$actual" = "$expected" ] || { echo "Checksum verification failed for $asset." >&2; exit 1; }

mkdir -p "$install_dir"
temporary="$install_dir/.hypertask.$$"
cp "$work_dir/$asset" "$temporary"
chmod 0755 "$temporary"
mv -f "$temporary" "$install_dir/hypertask"
printf 'Installed Hypertask CLI at %s\n' "$install_dir/hypertask"
