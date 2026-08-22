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
