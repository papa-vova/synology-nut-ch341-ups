# Troubleshooting

Start with:

```sh
./scripts/check-over-ssh.sh admin@nas
```

If it reports `NOT OK`, collect NAS-side details:

```sh
ssh admin@nas "sudo /usr/local/sbin/synology-ch341-ups-install.sh status"
ssh admin@nas "journalctl -u ch341-ups-watchdog.service -u ups-usb.service --since '30 minutes ago' --no-pager"
```

## DSM shows no USB UPS

Confirm the USB ID:

```sh
scp scripts/probe-nas-ups.sh admin@nas:/tmp/
ssh admin@nas "sudo /bin/sh /tmp/probe-nas-ups.sh"
```

If the UPS shows `1a86:7523`, DSM sees USB electrically, but the device is a CH341 serial bridge rather than HID.

## No `/dev/ttyUSB0`

Run on the NAS:

```sh
lsmod | grep -E '^(ch341|usbserial)'
dmesg | grep -iE 'ch341|ttyUSB|1a86|7523|usbserial' | tail -n 80
```

If `ch341.ko` does not load after a DSM update, rebuild it for the new DSM kernel and run `./scripts/deploy-over-ssh.sh admin@nas`.

## UPS status stays `OL` while mains is cut

Run on the NAS while the UPS is on battery:

```sh
/usr/bin/upsc ups@localhost ups.status
/usr/bin/upsc ups@localhost input.voltage
/usr/bin/upsc ups@localhost battery.voltage
```

If status remains `OL`, the UPS firmware or selected protocol is not reporting battery mode correctly.

## DSM does not shut down after the timer

Check the watchdog:

```sh
systemctl is-active ch341-ups-watchdog.timer
systemctl status ch341-ups-watchdog.service --no-pager
journalctl -u ch341-ups-watchdog.service --since "30 minutes ago" --no-pager
```

## UPS does not cut output

Check whether the driver has shutdown-delay parameters:

```sh
/usr/bin/upsc ups@localhost driver.parameter.offdelay
/usr/bin/upsc ups@localhost driver.parameter.ondelay
```

Some UPS firmware may ignore the Megatec/Qx shutdown-return command.
