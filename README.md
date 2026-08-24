# Synology NUT CH341 UPS

This project makes a Synology DSM NAS work with a USB-attached non-HID UPS that presents as a QinHeng CH340/CH341 serial bridge, commonly visible as USB ID `1a86:7523`.

The tested device was a Conceptronic UPS exposing USB `1a86:7523` and speaking a Megatec/Qx-style protocol over serial. The tested NAS platform was Synology Gemini Lake with DSM kernel `4.4.302+`.

## Problem

- DSM's stock USB UPS detection expects USB HID.
- This UPS is not HID; DSM sees a USB serial bridge, but does not configure it as a UPS.
- There is no off-the-shelf DSM/NUT setup that handles this end-to-end for this device class.
- After mains power is cut, DSM should wait for the configured UPS wait time, enter Safe/Standby safely, ask the UPS to cut output if supported, and recover automatically when mains returns.
- DSM notifications and logs should show whether monitoring is healthy.

## Solution Architecture

The setup stays as close as practical to stock DSM:

- DSM's own `nutdrv_qx`, `upsd`, `upsmon`, `upssched`, and `synoups` are used.
- The added `ch341.ko` module is loaded from `/usr/local`, creates `/dev/ttyUSB*` for the CH341 bridge, and leaves UPS monitoring to the stock NUT stack over that serial TTY.
- A DSM service drop-in points the stock UPS USB service at the serial-aware startup path.
- A watchdog timer runs the DSM-configured power-loss decision loop shown below and repairs the UPS status read path if it becomes unreadable before Safe/Standby starts.
- When the wait time expires or low battery is reported, a shutdown manager re-checks live UPS status, asks DSM to enter Safe/Standby, then tries to cut UPS output over the Megatec serial protocol.
- If this UPS refuses output-cut commands, the shutdown manager remains alive in Safe/Standby, polls the UPS directly, and reboots the NAS when mains returns.

### DSM Runtime

#### Boot Hook

- `ch341-ups.service` is enabled under `syno-bootup-done.target`; it restarts DSM's `ups-usb.service` after DSM finishes booting.
- The `ups-usb.service` drop-in starts DSM's stock NUT processes through the serial-aware wrapper.

#### Watchdog

- The watchdog is a DSM systemd timer, not a separate always-running process.
- It uses DSM's UPS/NUT status to detect prolonged battery mode and trigger the shutdown path shown in the outage sequence.
- If UPS status is unreadable before Safe/Standby starts, it force-restarts the UPS stack once and rechecks status before giving up.
- It reads DSM's UPS wait time at runtime. Wait-time expiry and low-battery/FSD events start the shutdown manager.

#### Output Shutdown

- The shutdown manager reads DSM's UPS-output-shutdown setting and re-checks live UPS status before entering the output-control path.
- If DSM UPS output shutdown is enabled and the UPS is still on battery, the shutdown manager waits for DSM Safe/Standby and then attempts UPS output shutdown from that safe state.
- If the UPS refuses output cut, the helper waits in Safe/Standby and reboots DSM after AC input returns.
- A compatibility hook covers DSM safe-shutdown flows that bypass the watchdog, so they still use the same serial-UPS recovery path.

#### Notifications

- UPS monitoring connect/recovery emits DSM's stock `The UPS has been connected` event.
- If monitoring is still unavailable after an automatic restart attempt, the watchdog emits DSM's stock `The UPS has been disconnected` event and logs the diagnostic details.

### Outage Sequence

```mermaid
sequenceDiagram
  autonumber
  participant M as mains power
  participant U as ups
  participant W as watchdog
  participant D as dsm
  participant O as output-shutdown helper

  M-->>U: power cut
  U-->>D: reports OB or LB over CH341 serial
  D-->>W: exposes UPS status and wait setting
  W->>W: start battery timer
  alt mains returns before timer expires
    M-->>U: power returns
    U-->>D: reports OL
    D-->>W: exposes OL
    W->>W: clear battery timer
  else timer expires
    W-->>O: start shutdown manager
    O->>O: re-check UPS status and output-shutdown setting
    alt still on battery
      O-->>D: request Safe/Standby
      D->>D: stop services and unmount volumes
      O-->>U: request Megatec output cut
      alt UPS accepts output cut
        U->>U: cut output after command delay
        M-->>U: power returns
        U->>U: wait ondelay, then restore output
        U-->>D: supply power
        D->>D: boot and start UPS services
      else UPS refuses output cut
        O->>O: poll UPS directly while DSM stays in Safe/Standby
        M-->>U: power returns
        U-->>O: reports AC input
        O-->>D: reboot DSM to restore services
      end
    else mains already returned
      O->>O: skip shutdown
    end
    D-->>W: expose current UPS status
    W->>W: verify monitoring and clear outage state
  end
```

### Monitoring Sequence

```mermaid
sequenceDiagram
  autonumber
  participant D as dsm
  participant W as watchdog

  D-->>W: starts timer after boot
  W-->>D: reads UPS status and DSM UPS settings
  alt UPS status readable
    W->>W: update outage state
  else monitoring broken
    W-->>D: force-restart UPS stack and recheck
    alt recovered
      W->>W: continue with recovered status
    else still broken
      W-->>D: emit stock UPS disconnected event and log diagnostic details
    end
  end
```

## Implementation

### Prepare

Run the Make targets on a Linux host, including WSL on Windows. The NAS does not need this repository, the Synology source archive, or the toolchain. Deployment uses SSH and copies only the installer and built module to the NAS.

#### Solution Parameters

Set local parameters:

```sh
export DSM_USER=admin
export NAS=nas
export WAIT_SECONDS=900
export UPS_OFF_DELAY_SECONDS=300
export UPS_ON_DELAY_SECONDS=180
```

- `NAS` is only the NAS hostname or SSH host alias used by `install`, `check`,
  and `probe`.
- `DSM_USER` is the DSM account used for SSH login and sudo authorization.
- `WAIT_SECONDS` is only the installer fallback for DSM's UPS wait time when DSM has no valid saved setting.
- `UPS_OFF_DELAY_SECONDS` and `UPS_ON_DELAY_SECONDS` configure NUT output cutoff/restore delay values for UPS firmware that honors NUT shutdown-return commands.

#### Passwordless Access Configuration (Mandatory)

The install flow is intentionally noninteractive. Configure SSH, DSM sudo, and
DSM notification delivery before running `make install`; interactive password
prompts are not part of the documented flow.

##### SSH Authentication

Configure SSH so the local build machine can connect to DSM without prompts:

- Enable the DSM SSH service.
- Make the local machine trust the NAS host key.
- Install the local SSH public key for the DSM account.
- Load any SSH key passphrase into `ssh-agent`, or use an unencrypted automation
  key if that matches your security policy.

This command must exit without any prompt:

```sh
ssh -o BatchMode=yes "$DSM_USER@$NAS" true
```

##### DSM Sudo

The DSM account must be allowed to run this repository's install/check/probe
commands through sudo without a password. Run this once after setting the
solution parameters; it replaces this repository's sudoers file with the current
rule:

```sh
setup_script="/tmp/synology-nut-ch341-ups-sudoers-setup.$$.sh"
ssh "$DSM_USER@$NAS" "cat > '$setup_script' && chmod 700 '$setup_script'" <<'EOF'
set -eu
DSM_USER="$1"
SETUP_SCRIPT="$2"

case "$DSM_USER" in
	""|*[!A-Za-z0-9._-]*)
		printf 'ERROR: invalid DSM_USER for sudoers rule: %s\n' "$DSM_USER" >&2
		exit 2
		;;
esac

sudoers=/etc/sudoers.d/synology-nut-ch341-ups
tmp="${sudoers}.tmp"

cat > "$tmp" <<EORULE
$DSM_USER ALL=(root) NOPASSWD: /bin/true, /bin/sh /tmp/synology-ch341-ups-install.sh *, /usr/local/sbin/ch341-ups.sh status, /usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_wait_time, /usr/syno/bin/synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_safeshutdown, /usr/syno/bin/synoups status, /bin/sh /tmp/probe-nas-ups.sh
EORULE

chmod 0440 "$tmp"
mv "$tmp" "$sudoers"
chmod 0440 "$sudoers"
rm -f "$SETUP_SCRIPT"
EOF

ssh -tt "$DSM_USER@$NAS" "sudo /bin/sh '$setup_script' '$DSM_USER' '$setup_script'; rc=\$?; rm -f '$setup_script'; exit \$rc"
```

Then test the installed rule with an actual passwordless sudo command. This
must exit without a password prompt:

```sh
ssh "$DSM_USER@$NAS" sudo -n /bin/true
```

#### DSM Settings

##### General DSM Options

- Control Panel -> Hardware & Power -> General: enable `Restart automatically when power supply issue is fixed`.
- Control Panel -> Notification -> Email: configure and test email delivery.

##### DSM Notification Rule

DSM decides which stock events are sent by email from Control Panel notification
rules. Before relying on remote UPS alerts, configure the email-enabled rule:

1. Open Control Panel -> Notification -> Rules.
2. Select the rule that has your email address in the Email column, for example
   `default`, and click Edit.
3. Expand Power System or Power supply.
4. Tick all events that you want to be notified about:
   - Info: `The UPS has been connected`
   - Critical: `The UPS has been disconnected`
   - Warning: `The UPS has entered battery mode`
   - Warning: `The UPS has reached low battery`
   - Info: `The UPS has returned to AC mode`
5. Save the rule and click Apply.

The installer does not change DSM Notification Rule membership. Configure these
checkboxes in DSM UI; the installer always emits the stock UPS events, and DSM
rules decide which delivery channels receive them.

##### DSM UPS Options

- Control Panel -> Hardware & Power -> UPS -> Enable UPS support: enabled.
- UPS type: `USB UPS`.
- Time before Synology NAS enters Standby Mode: `Customize time`; this DSM setting is the shutdown wait time used at runtime. `WAIT_SECONDS` only supplies the initial fallback when DSM has no valid saved wait time.
- `Shut down UPS when the system enters Standby Mode`: checked if the shutdown manager should try to cut UPS output during the shutdown path.
- `Until low battery`: not recommended for this UPS class because battery/runtime reporting is not reliable enough for the shutdown policy.

Choose the DSM wait time so real battery capacity leaves reserve for Safe/Standby and recovery. Changing the wait time or UPS-output-shutdown setting in DSM does not require reinstalling.

### Build And Install

Inspect `dependencies.env` first. It declares the Synology kernel source archive, toolchain archive, checksums, and platform name.

Download the configured dependencies:

```sh
make deps
```

Build the module from the already-downloaded dependencies:

```sh
make build
```

Install or update the UPS setup:

```sh
make install
```

Remove the installed NAS-side setup and restore backed-up DSM/NUT files:

```sh
make restore
```

Reboot DSM after `make restore` before doing a fresh install/test cycle.

### Normal Notifications

- UPS monitoring connect/recovery: UPS-connected event.
- Mains input loss: battery-mode event.
- Mains input restored: AC-return event.
- Low battery: low-battery event when the UPS/NUT reports low battery.
- DSM wait-time expiry starts the shutdown path; it is not treated as a low-battery notification.
- UPS disconnected/unavailable: UPS-disconnected event.
- DSM UPS settings changes are settings changes only; when monitoring is already healthy, they preserve the already-running UPS monitor instead of restarting it.
- Power-state events use the single DSM-facing path: `upsmon EXEC -> upssched -> wrapper -> synoups -> DSM stock UPS event`.
- `SYSLOG`/`WALL` are not enabled for those events on DSM, because they can create duplicate DSM notifications outside the `synoups` path.
- The last observed power state is kept in `/run/ch341-ups-power.state` across service restarts; it resets on NAS boot.

### Testing

#### Check

```sh
make check
```

`make check` is a manual DSM runtime report over SSH. Ongoing monitoring is handled by the watchdog timer installed on the NAS.

It verifies:

- CH341 kernel module and `/dev/ttyUSB*`
- NUT driver, server, and monitor processes
- DSM UPS services and timers
- watchdog UPS-stack recovery wiring
- output-shutdown helper wiring
- installed DSM/NUT event wiring for the five stock UPS events
- DSM UPS wait time and output-shutdown setting
- live DSM and NUT UPS status

Expected final line:

```text
UPS monitoring: PASS
```

#### Short Detection

1. Run `make check`.
2. Cut mains input to the UPS.
3. Wait 2 minutes.
4. Restore mains input.
5. Run `make check` again.

Expected:

- DSM sends a battery-mode notification (if configured).
- DSM sends the return-to-AC notification after power returns (if configured).
- NAS remains online.

#### Full Shutdown

1. Charge the UPS enough for the test.
2. Run `make check`.
3. Cut mains input to the UPS.
4. Wait longer than the configured DSM UPS wait time, or until the UPS reports low battery.
5. The shutdown manager re-checks status and asks DSM to enter Safe/Standby if the UPS is still `OB` or `LB`.
6. DSM enters Safe/Standby: services stop and volumes are unmounted.
7. If DSM output shutdown is enabled, the helper tries to cut UPS output from Safe/Standby.
8. If the UPS accepts output cut, output drops and later returns after mains returns.
9. If the UPS refuses output cut, the helper waits in Safe/Standby for AC input to return.
10. Restore mains input to the UPS.
11. Expected: the NAS boots normally after UPS output returns, or reboots from Safe/Standby when the helper detects AC return.
12. DSM sends the UPS-connected notification after the UPS stack starts (if configured).
13. Run `make check` again.

If the check reports a problem, use [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
