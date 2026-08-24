# Troubleshooting

Commands below assume the README target variables are set:

```sh
DSM_USER=admin
NAS=nas
SSH_TARGET="$DSM_USER@$NAS"
```

If `make check` reports `FAIL`, collect NAS-side details:

```sh
make check NAS="$NAS" DSM_USER="$DSM_USER"
ssh "$SSH_TARGET" "sudo /usr/local/sbin/ch341-ups.sh status"
ssh "$SSH_TARGET" "sudo journalctl -u ch341-ups-watchdog.service -u ch341-ups-output-shutdown.service -u ups-usb.service --since '30 minutes ago' --no-pager"
```

## DSM shows no USB UPS

Confirm the USB ID:

```sh
make probe
```

If the UPS shows `1a86:7523`, DSM sees USB electrically, but the device is a CH341 serial bridge rather than HID.

## No `/dev/ttyUSB0`

Run on the NAS:

```sh
lsmod | grep -E '^(ch341|usbserial)'
dmesg | grep -iE 'ch341|ttyUSB|1a86|7523|usbserial' | tail -n 80
```

If `ch341.ko` does not load after a DSM update, rebuild it for the new DSM kernel and run `make install`.

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

Then check whether the helper attempted the raw Megatec output-cut commands:

```sh
systemctl status ch341-ups-output-shutdown.service --no-pager
journalctl -u ch341-ups-output-shutdown.service --since "30 minutes ago" --no-pager
grep -iE 'raw Megatec|output shutdown|shutdown.return|Shutdown failed' /var/log/messages /var/log/systemd/ch341-ups-output-shutdown.service.log
grep -iE 'raw Megatec|output cut|AC returned|Safe/Standby' /var/log/ch341-ups-recovery.log
```

Some UPS firmware may ignore the Megatec/Qx shutdown-return command. In that
case the helper should stay alive in DSM Safe/Standby and use the AC-return
reboot fallback instead.

## NAS does not recover after mains returns

If the NAS enters Safe/Standby Mode but does not boot after AC returns, check
whether the output-cut path or the AC-return fallback ran:

```sh
grep -iE 'raw Megatec|output cut|AC returned|Safe/Standby|safe shutdown|watchdog|online|ups.status' /var/log/ch341-ups-recovery.log /var/log/ups.log /var/log/messages /var/log/systemd/ch341-ups-output-shutdown.service.log
```

The shutdown manager enters DSM Safe/Standby first. From there it tries UPS
output cut. If the UPS refuses output cut, the helper should remain alive,
poll the UPS directly, and reboot DSM when AC input returns.
