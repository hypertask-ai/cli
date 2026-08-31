#!/bin/sh
set -eu

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT HUP INT TERM
release_dir="$root/releases/latest/download"
install_dir="$root/install"
mkdir -p "$release_dir"
printf '#!/bin/sh\nprintf "native hypertask\\n"\n' > "$release_dir/hypertask-linux-x86_64"
chmod 0755 "$release_dir/hypertask-linux-x86_64"
(
  cd "$release_dir"
  sha256sum hypertask-linux-x86_64 > checksums.txt
)

fake_bin="$root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) printf 'Linux\n' ;;
esac
EOF
chmod 0755 "$fake_bin/uname"

PATH="$fake_bin:$PATH" \
HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
HYPERTASK_INSTALL_DIR="$install_dir" \
  ./scripts/install.sh >/dev/null
[ "$("$install_dir/hypertask")" = "native hypertask" ]

printf 'bad checksum  hypertask-linux-x86_64\n' > "$release_dir/checksums.txt"
if PATH="$fake_bin:$PATH" \
  HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
  HYPERTASK_INSTALL_DIR="$install_dir" \
  ./scripts/install.sh >/dev/null 2>&1; then
  echo "installer accepted a bad checksum" >&2
  exit 1
fi
