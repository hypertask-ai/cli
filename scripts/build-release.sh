#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
out_dir="$repo_root/dist"
rm -rf "$out_dir"
mkdir -p "$out_dir"
work_dir=$(mktemp -d)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

build_target() {
  target=$1
  asset=$2
  binary=$3
  prefix="$work_dir/$asset"
  zig build -Doptimize=ReleaseFast -Dtarget="$target" --prefix "$prefix"
  cp "$prefix/bin/$binary" "$out_dir/$asset"
  chmod 0755 "$out_dir/$asset"
}

build_target x86_64-linux-musl hypertask-linux-x86_64 hypertask
build_target aarch64-linux-musl hypertask-linux-aarch64 hypertask
build_target x86_64-macos hypertask-macos-x86_64 hypertask
build_target aarch64-macos hypertask-macos-aarch64 hypertask
build_target x86_64-windows hypertask-windows-x86_64.exe hypertask.exe

(
  cd "$out_dir"
  sha256sum hypertask-* > checksums.txt
)
