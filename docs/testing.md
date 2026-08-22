# Test Plan

## Preflight

Run on the NAS:

```sh
/usr/local/sbin/ch341-ups.sh status
/usr/syno/bin/synoups status
/usr/bin/upsc ups@localhost ups.status
/usr/local/sbin/ch341-ups-healthcheck.sh; echo rc=$?
systemctl list-timers ch341-ups-healthcheck.timer ch341-ups-watchdog.timer --no-pager
```

Expected:

- UPS status is `OL`.
- The healthcheck exits with `rc=0`.
- Both timers are active and enabled.

## Short Power-Loss Test

Use this to confirm detection without shutting the NAS down.

1. Cut mains input to the UPS.
2. Wait 2 minutes.
3. Restore mains input.

Expected:

- DSM sends an "entered battery mode" notification.
- `/var/log/messages` contains a watchdog line saying battery mode was seen.
- After mains returns, `/var/log/messages` contains a watchdog line saying mains was restored.
- The NAS remains online.

Useful log command:

```sh
journalctl -u ch341-ups-watchdog.service -u ups-usb.service --since "10 minutes ago" --no-pager
grep -iE 'ch341-ups|upsmon|upssched|battery|online|onbatt|lowbatt' /var/log/messages | tail -n 80
```

## Full Power-Loss Test

Use this only when it is acceptable for DSM to stop services.

1. Confirm `WAIT_SECONDS=900` and UPS status is `OL`.
2. Cut mains input to the UPS.
3. Wait longer than 15 minutes.
4. Confirm DSM starts entering Safe/Standby Mode.
5. The watchdog requests UPS shutdown-return while DSM is still fully running.
6. UPS output should cut after `UPS_OFF_DELAY_SECONDS`, default `300`.
7. Restore mains input to the UPS.
8. UPS output should return after `UPS_ON_DELAY_SECONDS`, default `180`.
9. The NAS should boot normally if DSM Hardware & Power has automatic restart after power failure enabled.

Expected diagnostics:

- Battery-mode DSM notification.
- Watchdog log at battery-mode detection.
- Watchdog log when the 900-second timer is reached.
- DSM Safe/Standby Mode notification.
- Healthcheck `rc=0` after the NAS boots again.
