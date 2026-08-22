#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin
UPS_NAME="${UPS_NAME:-ups}"

echo "Kernel and model:"
uname -a
cat /proc/sys/kernel/syno_hw_version 2>/dev/null || true

echo
echo "USB devices:"
if command -v lsusb >/dev/null 2>&1; then
  lsusb
elif command -v synousbdisk >/dev/null 2>&1; then
  synousbdisk -info || true
else
  find /sys/bus/usb/devices -maxdepth 2 -type f \( -name idVendor -o -name idProduct -o -name product \) -print -exec cat {} \; 2>/dev/null || true
fi

echo
echo "Serial modules and TTY devices:"
lsmod | grep -E "^(ch341|usbserial)" || true
ls -l /dev/ttyUSB* 2>/dev/null || true

echo
echo "NUT programs:"
for bin in /usr/bin/nutdrv_qx /usr/bin/upsc /usr/bin/upsdrvctl /usr/sbin/upsd /usr/sbin/upsmon /usr/sbin/upssched /usr/syno/bin/synoups; do
  [ -x "$bin" ] && echo "$bin"
done

echo
echo "UPS status:"
/usr/bin/upsc "$UPS_NAME@localhost" ups.status 2>&1 || true
/usr/bin/upsc "$UPS_NAME@localhost" input.voltage 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.voltage 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.charge 2>/dev/null || true
/usr/bin/upsc "$UPS_NAME@localhost" battery.runtime 2>/dev/null || true

echo
echo "Services:"
systemctl is-active ups-usb.service 2>/dev/null || true
systemctl is-active ch341-ups.service 2>/dev/null || true
systemctl is-active ch341-ups-healthcheck.timer 2>/dev/null || true
systemctl is-active ch341-ups-watchdog.timer 2>/dev/null || true
