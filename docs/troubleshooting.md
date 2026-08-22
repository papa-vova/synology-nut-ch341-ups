# Troubleshooting

## DSM shows no USB UPS

Check that the UPS is not presenting as HID:

```sh
lsusb
```

If it shows `1a86:7523`, DSM sees USB electrically, but the device is a CH341 serial bridge. This setup is intended for that case.

## No `/dev/ttyUSB0`

Check the module:

```sh
lsmod | grep -E '^(ch341|usbserial)'
dmesg | grep -iE 'ch341|ttyUSB|1a86|7523|usbserial' | tail -n 80
```

If `ch341.ko` does not load after a DSM update, rebuild it against the matching Synology GPL source/toolchain for the new kernel.

## UPS status stays `OL` while mains is cut

The NAS only reacts to the status reported by the UPS through NUT. Run:

```sh
/usr/bin/upsc ups@localhost ups.status
/usr/bin/upsc ups@localhost input.voltage
/usr/bin/upsc ups@localhost battery.voltage
```

If status remains `OL` while the UPS is physically on battery, the UPS firmware/driver protocol is not reporting battery mode correctly.

## DSM does not shut down after the timer

Check the watchdog:

```sh
systemctl is-active ch341-ups-watchdog.timer
systemctl status ch341-ups-watchdog.service --no-pager
journalctl -u ch341-ups-watchdog.service --since "30 minutes ago" --no-pager
```

The watchdog is the root-owned process responsible for the fixed battery timer.

## UPS does not cut output

Check whether the UPS exposes shutdown delay parameters:

```sh
/usr/bin/upsc ups@localhost driver.parameter.offdelay
/usr/bin/upsc ups@localhost driver.parameter.ondelay
```

The driver sends the shutdown-return command through DSM/NUT. Some UPS firmware may ignore or partially implement that command.

## Notifications stop after a DSM update

Run:

```sh
/usr/local/sbin/ch341-ups-healthcheck.sh; echo rc=$?
systemctl status ch341-ups-healthcheck.timer --no-pager
```

The healthcheck tries one automatic service restart. If the setup remains broken, it sends a DSM notification to administrators with email delivery requested.
