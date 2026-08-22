#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 user@nas" >&2; exit 2; }

ssh "$target" 'sudo /usr/local/sbin/ch341-ups-healthcheck.sh >/tmp/synology-nut-ch341-check.log 2>&1; rc=$?; if [ "$rc" -eq 0 ]; then echo "OK: UPS monitoring is healthy"; /usr/syno/bin/synoups status 2>/dev/null || true; /usr/bin/upsc ups@localhost ups.status 2>/dev/null || true; exit 0; fi; echo "NOT OK: UPS monitoring check failed"; cat /tmp/synology-nut-ch341-check.log; sudo /usr/local/sbin/synology-ch341-ups-install.sh status; exit "$rc"'
