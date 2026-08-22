#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 user@nas" >&2; exit 2; }

module="${MODULE:-$root_dir/.work/out/ch341.ko}"
[ -f "$module" ] || { echo "missing module: $module" >&2; exit 1; }

scp "$root_dir/scripts/synology-ch341-ups-install.sh" "$module" "$target:/tmp/"

remote_args=()
[ -n "${WAIT_SECONDS:-}" ] && remote_args+=("WAIT_SECONDS=$WAIT_SECONDS")
[ -n "${UPS_OFF_DELAY_SECONDS:-}" ] && remote_args+=("UPS_OFF_DELAY_SECONDS=$UPS_OFF_DELAY_SECONDS")
[ -n "${UPS_ON_DELAY_SECONDS:-}" ] && remote_args+=("UPS_ON_DELAY_SECONDS=$UPS_ON_DELAY_SECONDS")

remote_cmd="sudo /usr/local/sbin/synology-nut-ch341-apply.sh"
if [ "${#remote_args[@]}" -gt 0 ]; then
  printf -v quoted_args ' %q' "${remote_args[@]}"
  remote_cmd="$remote_cmd$quoted_args"
fi

ssh "$target" "$remote_cmd"
