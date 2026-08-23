#!/bin/sh
set -eu

# Environment:
#   UPS_NAME   Local NUT UPS name to query. Default: ups.

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin
UPS_NAME="${UPS_NAME:-ups}"

section() {
  logger -p user.info -t ch341-ups "probe: $*" 2>/dev/null || true
  printf '\n## %s\n' "$*"
}

section "Kernel and model"
uname -a
cat /proc/sys/kernel/syno_hw_version 2>/dev/null || true

section "USB devices"
if command -v lsusb >/dev/null 2>&1; then
  lsusb
elif command -v synousbdisk >/dev/null 2>&1; then
  synousbdisk -info || true
else
  find /sys/bus/usb/devices -maxdepth 2 -type f \( -name idVendor -o -name idProduct -o -name product \) -print -exec cat {} \; 2>/dev/null || true
fi

section "Serial modules and TTY devices"
lsmod | grep -E "^(ch341|usbserial)" || true
ls -l /dev/ttyUSB* 2>/dev/null || true

section "NUT programs"
for bin in /usr/bin/nutdrv_qx /usr/bin/upsc /usr/bin/upsdrvctl /usr/sbin/upsd /usr/sbin/upsmon /usr/sbin/upssched /usr/syno/bin/synoups; do
  [ -x "$bin" ] && printf '%s\n' "$bin"
done

section "UPS status"
/usr/bin/upsc "$UPS_NAME@localhost" ups.status 2>&1 || true
/usr/bin/upsc "$UPS_NAME@localhost" input.voltage 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.voltage 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.charge 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.runtime 2>/dev/null || true

section "Services"
systemctl is-active ups-usb.service 2>/dev/null || true
systemctl is-active ch341-ups.service 2>/dev/null || true
systemctl is-active ch341-ups-healthcheck.timer 2>/dev/null || true
systemctl is-active ch341-ups-watchdog.timer 2>/dev/null || true
systemctl is-active ch341-ups-output-shutdown.service 2>/dev/null || true

section "Shutdown state"
printf 'shutdown.target=%s\n' "$(synosystemctl get-active-status shutdown.target 2>/dev/null || true)"
printf 'safe-shutdown.target=%s\n' "$(synosystemctl get-active-status safe-shutdown.target 2>/dev/null || true)"
printf 'safe-shutdown.service=%s\n' "$(systemctl is-active safe-shutdown.service 2>/dev/null || true)"
printf 'output-helper=%s\n' "$(systemctl is-active ch341-ups-output-shutdown.service 2>/dev/null || true)"
ls -l /tmp/ups.safedown /etc/killpower /run/ch341-ups-safemode.requested 2>/dev/null || true
for marker in /tmp/ups.safedown /etc/killpower /run/ch341-ups-safemode.requested; do
  [ -f "$marker" ] || continue
  printf '\n-- %s --\n' "$marker"
  cat "$marker" 2>/dev/null || true
done

section "UPS config"
synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_wait_time 2>/dev/null || true
synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_safeshutdown 2>/dev/null || true
grep -E '^[[:space:]]*(offdelay|ondelay|driver|port|protocol)[[:space:]]*=' /etc/ups/ups.conf 2>/dev/null || true
grep -E '^NOTIFYFLAG (ONBATT|ONLINE|LOWBATT|FSD)|^NOTIFYCMD' /etc/ups/upsmon.conf 2>/dev/null || true
grep -E '^CMDSCRIPT|^AT (ONBATT|ONLINE|LOWBATT|FSD)' /etc/ups/upssched.conf 2>/dev/null || true

section "Recent UPS shutdown logs"
for log in \
  /var/log/messages \
  /var/log/ups.log \
  /var/log/systemd/ch341-ups-watchdog.service.log \
  /var/log/systemd/ch341-ups-output-shutdown.service.log \
  /var/log/systemd/safe-shutdown.service.log \
  /var/log/systemd/ups-usb.service.log
do
  [ -r "$log" ] || continue
  printf '\n-- %s --\n' "$log"
  grep -hE 'ch341|synoups|upsmsg|safe-shutdown|output shutdown|upsdrvctl shutdown|shutdown.return|Shutdown failed|wait time|Safe Mode|safe shutdown|online|lowbatt|fsd|UPS safe shutdown|UPS shutdown|Server going to Safe Shutdown|Server is on battery|Server back online' "$log" 2>/dev/null | tail -n 80 || true
done
