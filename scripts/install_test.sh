#!/bin/sh
set -eu

root=$(mktemp -d)
cleanup() { rm -rf "$root"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
release_dir="$root/releases/latest/download"
install_dir="$root/install"
mkdir -p "$release_dir"
printf '#!/bin/sh\nprintf "native hypertask\\n"\n' > "$release_dir/hypertask-linux-x86_64"
chmod 0755 "$release_dir/hypertask-linux-x86_64"
(
  cd "$release_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum hypertask-linux-x86_64 > checksums.txt
  else
    shasum -a 256 hypertask-linux-x86_64 > checksums.txt
  fi
)
versioned_release_dir="$root/releases/download/v0.2.0"
mkdir -p "$versioned_release_dir"
cp "$release_dir/hypertask-linux-x86_64" "$release_dir/checksums.txt" "$versioned_release_dir/"

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
HYPERTASK_CLI_VERSION=latest \
HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
HYPERTASK_INSTALL_DIR="$install_dir" \
  ./scripts/install.sh >/dev/null
[ "$("$install_dir/hypertask")" = "native hypertask" ]

for version in 0.2.0 v0.2.0; do
  version_install_dir="$root/install-$version"
  PATH="$fake_bin:$PATH" \
  HYPERTASK_CLI_VERSION="$version" \
  HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
  HYPERTASK_INSTALL_DIR="$version_install_dir" \
    ./scripts/install.sh >/dev/null
  [ "$("$version_install_dir/hypertask")" = "native hypertask" ]
done

blocked_dir="$root/blocked-install"
mkdir -p "$blocked_dir/hypertask"
if PATH="$fake_bin:$PATH" \
  HYPERTASK_CLI_VERSION=latest \
  HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
  HYPERTASK_INSTALL_DIR="$blocked_dir" \
  ./scripts/install.sh >/dev/null 2>&1; then
  echo "installer accepted a directory destination" >&2
  exit 1
fi

printf '%064d  hypertask-linux-x86_64\n' 0 > "$release_dir/checksums.txt"
if PATH="$fake_bin:$PATH" \
  HYPERTASK_CLI_VERSION=latest \
  HYPERTASK_CLI_RELEASE_ROOT="file://$root/releases" \
  HYPERTASK_INSTALL_DIR="$install_dir" \
  ./scripts/install.sh >/dev/null 2>&1; then
  echo "installer accepted a bad checksum" >&2
  exit 1
fi
