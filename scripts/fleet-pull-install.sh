#!/usr/bin/env bash
set -euo pipefail

dry_run=false
case ${1:-} in
  --dry-run) dry_run=true ;;
  '') ;;
  *) printf 'usage: %s [--dry-run]\n' "$0" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { printf 'too many arguments\n' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
libexec="$HOME/.local/libexec/hypertask-fleet"
units="$HOME/.config/systemd/user"
service='[Unit]
Description=Hypertask fleet release pull

[Service]
Type=oneshot
Nice=19
ExecStart="%h/.local/libexec/hypertask-fleet/fleet-pull.sh"
'
timer='[Unit]
Description=Hypertask fleet release pull timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
'

if [[ "$dry_run" == true ]]; then
  printf 'Would copy with mode 755:\n  %s -> %s/fleet-pull.sh\n  %s -> %s/install-fleet.sh\n' \
    "$script_dir/fleet-pull.sh" "$libexec" "$script_dir/install-fleet.sh" "$libexec"
  printf 'Would write %s/hypertask-fleet-pull.service:\n%s\n' "$units" "$service"
  printf 'Would write %s/hypertask-fleet-pull.timer:\n%s\n' "$units" "$timer"
  printf 'Would run: systemctl --user daemon-reload && systemctl --user enable --now hypertask-fleet-pull.timer\n'
  exit 0
fi

mkdir -p "$libexec" "$units"
install -m 755 "$script_dir/fleet-pull.sh" "$script_dir/install-fleet.sh" "$libexec/"
printf '%s\n' "$service" > "$units/hypertask-fleet-pull.service"
printf '%s\n' "$timer" > "$units/hypertask-fleet-pull.timer"
systemctl --user daemon-reload
systemctl --user enable --now hypertask-fleet-pull.timer
