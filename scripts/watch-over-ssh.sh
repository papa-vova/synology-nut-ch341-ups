#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   watch-over-ssh.sh user@nas [interval_seconds]
#
# Lightweight live monitor for physical UPS tests. This avoids running the
# healthcheck loop during an outage, because healthcheck can restart services.

target="${1:-}"
interval="${2:-15}"

usage() {
  printf 'Usage: %s user@nas [interval_seconds]\n' "$0" >&2
  exit 2
}

[ -n "$target" ] || usage

case "$interval" in
  ""|*[!0-9]*) usage ;;
esac

probe="$(mktemp)"
cleanup() {
  rm -f "$probe"
}
trap cleanup EXIT

cat >"$probe" <<'REMOTE'
#!/bin/sh
set +e

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

printf 'remote=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
printf 'wait=%s output_shutdown=%s\n' \
  "$(synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_wait_time 2>/dev/null)" \
  "$(synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_safeshutdown 2>/dev/null)"
printf 'nut=%s input=%s batt_v=%s charge=%s runtime=%s\n' \
  "$(/usr/bin/timeout 6 /usr/bin/upsc ups@localhost ups.status 2>&1)" \
  "$(/usr/bin/timeout 6 /usr/bin/upsc ups@localhost input.voltage 2>&1)" \
  "$(/usr/bin/timeout 6 /usr/bin/upsc ups@localhost battery.voltage 2>&1)" \
  "$(/usr/bin/timeout 6 /usr/bin/upsc ups@localhost battery.charge 2>&1)" \
  "$(/usr/bin/timeout 6 /usr/bin/upsc ups@localhost battery.runtime 2>&1)"
printf 'targets shutdown=%s safe_shutdown=%s output_helper=%s\n' \
  "$(synosystemctl get-active-status shutdown.target 2>/dev/null)" \
  "$(synosystemctl get-active-status safe-shutdown.target 2>/dev/null)" \
  "$(systemctl is-active ch341-ups-output-shutdown.service 2>/dev/null)"
printf 'services ups_usb=%s watchdog_timer=%s health_timer=%s\n' \
  "$(systemctl is-active ups-usb.service 2>/dev/null)" \
  "$(systemctl is-active ch341-ups-watchdog.timer 2>/dev/null)" \
  "$(systemctl is-active ch341-ups-healthcheck.timer 2>/dev/null)"
printf 'markers=%s\n' "$(ls /tmp/ups.safedown /etc/killpower /run/ch341-ups-safemode.requested 2>/dev/null | tr '\n' ' ')"

for log in \
  /var/log/messages \
  /var/log/ups.log \
  /var/log/systemd/ch341-ups-watchdog.service.log \
  /var/log/systemd/ch341-ups-output-shutdown.service.log \
  /var/log/systemd/ups-usb.service.log
do
  [ -r "$log" ] || continue
  hits="$(grep -hE 'ch341|synoups|upsmsg|safe-shutdown|output shutdown|upsdrvctl shutdown|shutdown.return|Shutdown failed|wait time|Safe Mode|safe shutdown|online|lowbatt|fsd' "$log" 2>/dev/null | tail -n 3)"
  [ -n "$hits" ] || continue
  printf 'log:%s\n%s\n' "$log" "$hits"
done
REMOTE

upload_probe() {
  scp -O \
    -o ConnectTimeout=8 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    "$probe" "$target:/tmp/probe-nas-ups.sh" >/dev/null
}

while true; do
  printf '\n=== local=%s ===\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
  if ! upload_probe || ! ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$target" "sudo /bin/sh /tmp/probe-nas-ups.sh"; then
    printf 'ssh=DOWN\n'
  fi
  sleep "$interval"
done
