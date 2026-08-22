#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"

usage() {
  printf 'Usage: %s user@nas\n' "$0" >&2
  exit 2
}

[ -n "$target" ] || usage

ssh "$target" 'sh -s' <<'REMOTE'
set +e

fail=0

first_line() {
  printf '%s\n' "$1" | sed -n '1p'
}

ok() {
  label="$1"
  detail="${2:-}"
  printf 'PASS %-35s %s\n' "$label" "$detail"
}

bad() {
  label="$1"
  detail="${2:-}"
  fail=1
  printf 'FAIL %-35s %s\n' "$label" "$detail"
}

check_command() {
  label="$1"
  shift
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$label" "$(first_line "$out")"
  else
    bad "$label" "$(first_line "$out")"
  fi
}

check_active() {
  unit="$1"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    ok "$unit" "active"
  else
    bad "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
  fi
}

check_enabled() {
  unit="$1"
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    ok "$unit" "enabled"
  else
    bad "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null)"
  fi
}

health_out="$(sudo /usr/local/sbin/ch341-ups-healthcheck.sh 2>&1)"
health_rc=$?
if [ "$health_rc" -eq 0 ]; then
  ok "healthcheck" "passed"
else
  bad "healthcheck" "$(first_line "$health_out")"
fi

if lsmod | grep -q '^ch341 '; then
  ok "kernel module ch341" "loaded"
else
  bad "kernel module ch341" "not loaded"
fi

tty="$(ls /dev/ttyUSB* 2>/dev/null | sed -n '1p')"
if [ -n "$tty" ]; then
  ok "serial TTY" "$tty"
else
  bad "serial TTY" "no /dev/ttyUSB*"
fi

for process in nutdrv_qx upsd upsmon; do
  if ps aux | grep -v grep | grep -q "$process"; then
    ok "process $process" "running"
  else
    bad "process $process" "not running"
  fi
done

check_active ups-usb.service
check_active ch341-ups.service
check_active ch341-ups-healthcheck.timer
check_enabled ch341-ups-healthcheck.timer
check_active ch341-ups-watchdog.timer
check_enabled ch341-ups-watchdog.timer

wait_time="$(/usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_wait_time 2>/dev/null)"
if [ -n "$wait_time" ]; then
  ok "DSM UPS wait time" "${wait_time}s"
else
  bad "DSM UPS wait time" "not readable"
fi

safe_shutdown="$(/usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_safeshutdown 2>/dev/null)"
if [ -n "$safe_shutdown" ]; then
  ok "DSM UPS output shutdown" "$safe_shutdown"
else
  bad "DSM UPS output shutdown" "not readable"
fi

synoups_status="$(/usr/syno/bin/synoups status 2>&1)"
case "$synoups_status" in
  *OL*|*OB*|*LB*) ok "DSM UPS status" "$(first_line "$synoups_status")" ;;
  *) bad "DSM UPS status" "$(first_line "$synoups_status")" ;;
esac

nut_status="$(/usr/bin/upsc ups@localhost ups.status 2>&1)"
case "$nut_status" in
  *OL*|*OB*|*LB*) ok "NUT UPS status" "$(first_line "$nut_status")" ;;
  *) bad "NUT UPS status" "$(first_line "$nut_status")" ;;
esac

if [ "$fail" -eq 0 ]; then
  printf '%s\n' "UPS monitoring: PASS"
  exit 0
fi

printf '%s\n' "UPS monitoring: FAIL - see failed checks above"
exit 1
REMOTE
