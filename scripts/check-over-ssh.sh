#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   check-over-ssh.sh user@nas
#
# The remote DSM user must already have the passwordless sudo permissions
# documented in README.md. Output is a copy/pasteable runtime report.

target="${1:-}"

usage() {
  printf 'Usage: %s user@nas\n' "$0" >&2
  exit 2
}

[ -n "$target" ] || usage

ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$target" 'sh -s' <<'REMOTE'
set +e

fail=0

first_line() {
  printf '%s\n' "$1" | sed -n '1p'
}

first_line_or_timeout() {
  value="$1"
  [ -n "$value" ] || value="timed out"
  first_line "$value"
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

module_dst="/usr/local/lib/modules/ch341-ups/ch341.ko"
kernel="$(uname -r)"
if [ -f "$module_dst" ]; then
  vermagic="$(/bin/grep -ao 'vermagic=[^[:space:]]*' "$module_dst" 2>/dev/null | awk -F= 'NR == 1 {print $2}')"
  if [ -n "$vermagic" ] && [ "$vermagic" != "$kernel" ]; then
    bad "kernel module file" "vermagic $vermagic != running kernel $kernel"
  else
    ok "kernel module file" "$module_dst"
  fi
else
  bad "kernel module file" "$module_dst missing"
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
check_active ch341-ups-watchdog.timer
check_enabled ch341-ups-watchdog.timer

if systemctl cat ups-usb.service 2>/dev/null | grep -Fq 'ExecStart=/usr/local/sbin/ch341-ups.sh start'; then
  ok "ups-usb.service wrapper" "installed"
else
  bad "ups-usb.service wrapper" "missing or not wired"
fi

if systemctl cat ch341-ups-output-shutdown.service 2>/dev/null | grep -Fq 'ExecStart=/usr/local/sbin/ch341-ups-output-shutdown.sh'; then
  ok "ch341-ups-output-shutdown.service" "installed"
else
  bad "ch341-ups-output-shutdown.service" "missing or not wired"
fi

if grep -Fq "NOTIFYCMD /usr/sbin/upssched" /etc/ups/upsmon.conf 2>/dev/null &&
   grep -Fq "NOTIFYFLAG ONBATT EXEC" /etc/ups/upsmon.conf 2>/dev/null &&
   grep -Fq "NOTIFYFLAG ONLINE EXEC" /etc/ups/upsmon.conf 2>/dev/null &&
   grep -Fq "NOTIFYFLAG LOWBATT EXEC" /etc/ups/upsmon.conf 2>/dev/null &&
   grep -Fq "NOTIFYFLAG FSD EXEC" /etc/ups/upsmon.conf 2>/dev/null &&
   grep -Fq "CMDSCRIPT /usr/local/sbin/ch341-upssched-cmd.sh" /etc/ups/upssched.conf 2>/dev/null &&
   grep -Fq "AT ONBATT * EXECUTE onbatt" /etc/ups/upssched.conf 2>/dev/null &&
   grep -Fq "AT ONLINE * EXECUTE online" /etc/ups/upssched.conf 2>/dev/null &&
   grep -Fq "AT LOWBATT * EXECUTE lowbatt" /etc/ups/upssched.conf 2>/dev/null &&
   grep -Fq "AT FSD * EXECUTE fsd" /etc/ups/upssched.conf 2>/dev/null; then
  ok "DSM/NUT event wiring" "installed"
else
  bad "DSM/NUT event wiring" "missing or not wired"
fi

if grep -Fq "force_restart_ups_stack()" /usr/local/sbin/ch341-ups-watchdog.sh 2>/dev/null; then
  ok "watchdog UPS-stack recovery" "installed"
else
  bad "watchdog UPS-stack recovery" "missing"
fi

if grep -Fq "DSM Safe/Standby detected" /usr/local/sbin/ch341-ups-output-shutdown.sh 2>/dev/null &&
   grep -Fq "AC-return Safe/Standby reboot path" /usr/local/sbin/ch341-ups-output-shutdown.sh 2>/dev/null; then
  ok "shutdown manager policy" "Safe/Standby first, output cut or AC-return reboot"
else
  bad "shutdown manager policy" "not wired"
fi

wait_time="$(sudo /usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_wait_time 2>/dev/null)"
if [ -n "$wait_time" ]; then
  ok "DSM UPS wait time" "${wait_time}s"
else
  bad "DSM UPS wait time" "not readable"
fi

safe_shutdown="$(sudo /usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_safeshutdown 2>/dev/null)"
if [ -n "$safe_shutdown" ]; then
  ok "DSM UPS output shutdown" "$safe_shutdown"
else
  bad "DSM UPS output shutdown" "not readable"
fi

if [ -e /tmp/ups.safedown ]; then
  bad "DSM UPS status" "skipped: DSM safe-down marker active"
else
  synoups_status="$(/usr/bin/timeout 8 sudo /usr/syno/bin/synoups status 2>&1)"
  case "$synoups_status" in
    *OL*|*OB*|*LB*) ok "DSM UPS status" "$(first_line "$synoups_status")" ;;
    *) bad "DSM UPS status" "$(first_line_or_timeout "$synoups_status")" ;;
  esac
fi

nut_status="$(/usr/bin/timeout 8 /usr/bin/upsc ups@localhost ups.status 2>&1)"
case "$nut_status" in
  *OL*|*OB*|*LB*) ok "NUT UPS status" "$(first_line "$nut_status")" ;;
  *) bad "NUT UPS status" "$(first_line_or_timeout "$nut_status")" ;;
esac

if [ "$fail" -eq 0 ]; then
  printf '%s\n' "UPS monitoring: PASS"
  exit 0
fi

printf '%s\n' "UPS monitoring: FAIL - see failed checks above"
exit 1
REMOTE
