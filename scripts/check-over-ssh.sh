#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   check-over-ssh.sh user@nas
#
# The remote DSM user must already have the passwordless sudo permissions
# documented in README.md. The check runs through the installer subcommand so
# root-owned DSM/NUT files can be inspected without broad sudo permissions.

target="${1:-}"

usage() {
  printf 'Usage: %s user@nas\n' "$0" >&2
  exit 2
}

[ -n "$target" ] || usage

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="$script_dir/synology-ch341-ups-install.sh"
remote_installer="/tmp/synology-ch341-ups-install.sh"

[ -f "$installer" ] || {
  printf 'ERROR: installer not found: %s\n' "$installer" >&2
  exit 1
}

scp -O -o ConnectTimeout=8 "$installer" "$target:$remote_installer"
ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$target" \
  "sudo /bin/sh '$remote_installer' check"
