#!/bin/sh
set -eu

out_dir="$PWD/dist"
mkdir -p "$out_dir"
find "$out_dir" -maxdepth 1 -type f \( -name 'hypertask-*' -o -name checksums.txt \) -delete
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

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
