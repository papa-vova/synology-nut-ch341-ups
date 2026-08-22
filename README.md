# Synology NUT CH341 UPS

This project makes a Synology DSM NAS work with a USB-attached non-HID UPS that presents as a QinHeng CH340/CH341 serial bridge, commonly visible as USB ID `1a86:7523`.

The tested device was a Conceptronic UPS exposing USB `1a86:7523` and speaking a Megatec/Qx-style protocol over serial. The tested NAS platform was Synology Gemini Lake with DSM kernel `4.4.302+`.

## Problem

- DSM's stock USB UPS detection expects USB HID.
- This UPS is not HID; DSM sees a USB serial bridge, but does not configure it as a UPS.
- There is no off-the-shelf DSM/NUT setup that handles this end-to-end for this device class.
- After mains power is cut, DSM should wait for the configured UPS wait time, enter Safe/Standby Mode, ask the UPS to cut output, and later boot normally when UPS output returns.
- DSM notifications and logs should show whether monitoring is healthy.

## Solution Architecture

The setup stays as close as practical to stock DSM:

- DSM's own `nutdrv_qx`, `upsd`, `upsmon`, `upssched`, and `synoups` are used.
- The added kernel module only creates `/dev/ttyUSB*` for the CH341 bridge.
- A DSM service drop-in points the stock UPS USB service at the serial-aware startup path.
- A watchdog owns the DSM-configured power-loss timer.
- A healthcheck timer verifies the setup after boot and after DSM updates, then notifies DSM administrators if it breaks.

Build/deploy path:

- `dependencies.env` selects the Synology GPL kernel source, Synology toolchain, checksums, and DSM platform.
- `make deps` downloads the configured source/toolchain archives to the local build workspace.
- `make build` builds only `ch341.ko`; it does not build or replace the DSM kernel.
- `make bootstrap` and `make install` copy `ch341.ko` and the installer to DSM over SSH.
- DSM loads `ch341.ko` from `/usr/local`, gets `/dev/ttyUSB*`, then uses the stock NUT stack against that serial TTY.

Sequence:

```mermaid
sequenceDiagram
  autonumber
  participant M as mains power
  participant U as ups
  participant W as watchdog
  participant D as dsm

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
    W-->>U: request shutdown-return
    W-->>D: request Safe/Standby Mode
    D->>D: stop services and protect volumes
    U->>U: wait offdelay, then cut output
    M-->>U: power returns
    U->>U: wait ondelay, then restore output
    U-->>D: supply power
    D->>D: boot and start UPS services
    D-->>W: expose current UPS status
    W->>W: verify monitoring and clear outage state
  end
```

State machine:

```mermaid
stateDiagram-v2
  state "Mains powered" as MainsPowered
  state "Battery grace period" as BatteryGrace
  state "Shutdown requested" as ShutdownRequested
  state "DSM Safe/Standby" as DSMSafeStandby
  state "UPS output off" as UPSOutputOff
  state "Booting" as Booting

  [*] --> MainsPowered
  MainsPowered --> BatteryGrace: UPS reports OB or LB
  BatteryGrace --> MainsPowered: UPS reports OL before DSM wait time
  BatteryGrace --> ShutdownRequested: DSM wait time expires
  ShutdownRequested --> DSMSafeStandby: DSM accepts Safe/Standby request
  DSMSafeStandby --> UPSOutputOff: UPS offdelay expires
  UPSOutputOff --> Booting: mains returns and UPS restores output
  Booting --> MainsPowered: healthcheck passes with OL
  Booting --> BatteryGrace: healthcheck passes with OB or LB
```

## Implementation

### Prepare

Run the Make targets on a Linux host, including WSL on Windows. The NAS does not need this repository, the Synology source archive, or the toolchain. Deployment uses SSH and copies only the installer and built module to the NAS.

Set local parameters:

```sh
export DSM_USER=admin
export NAS="$DSM_USER@nas"
export WAIT_SECONDS=900
export UPS_OFF_DELAY_SECONDS=300
export UPS_ON_DELAY_SECONDS=180
```

Parameter overview:

- `NAS` is the SSH target used by `bootstrap`, `install`, `check`, and `probe`.
- `DSM_USER` is the DSM account authorized by `bootstrap`; normally it is the user part of `NAS`.
- `WAIT_SECONDS` is only the initial DSM UPS wait time written during install. Later UI changes are respected.
- `UPS_OFF_DELAY_SECONDS` and `UPS_ON_DELAY_SECONDS` configure UPS output cutoff/restore delays.
- `MODULE` points to the built `ch341.ko` if it is not in the default build location.
- `DEPS_FILE` points to the explicit Synology dependency configuration. Default: `dependencies.env`.
- `WORK_DIR` is the local download/build workspace. Default: `./.work/build`.

The Makefile and scripts document the exact variables they accept.

Verify SSH:

```sh
ssh "$NAS" true
```

Set DSM options:

- Control Panel -> Hardware & Power -> General: enable `Restart automatically when power supply issue is fixed`.
- Control Panel -> Notification -> Email: configure email delivery if email alerts are required.

UPS options after install:

- Control Panel -> Hardware & Power -> UPS -> Enable UPS support: enabled.
- UPS type: `USB UPS`.
- Time before Synology NAS enters Standby Mode: `Customize time`; default install value is 15 minutes.
- `Shut down UPS when the system enters Standby Mode`: checked if the UPS should cut output after DSM enters Safe/Standby Mode.
- `Until low battery`: not recommended for this UPS class because battery/runtime reporting is not reliable enough for the shutdown policy.

The watchdog reads DSM's UPS wait time and UPS-output-shutdown setting at runtime. Changing those two UI settings does not require reinstalling.

### Build

Inspect `dependencies.env` first. It declares the Synology kernel source archive, toolchain archive, checksums, and platform name.

Download the configured dependencies:

```sh
make deps
```

Build the module from the already-downloaded dependencies:

```sh
make build
```

For another platform or source set, edit `dependencies.env` or set `DEPS_FILE` to another file with the same variables.

### Install

Prepare DSM permissions once:

```sh
make bootstrap
```

This copies the NAS-side installer and module to `/tmp` over SSH, then runs one `sudo` command on DSM. If DSM asks for the sudo password, enter it in the local terminal. No manual shell work on the NAS is required.

It installs a root-owned apply command and a sudoers entry for the chosen `DSM_USER`, so later `make install` and `make check` can run without prompts.

Install or update the UPS setup:

```sh
make install
```

Override install parameters when needed:

```sh
make install WAIT_SECONDS=900 UPS_OFF_DELAY_SECONDS=300 UPS_ON_DELAY_SECONDS=180
```

### Check

There are two checks:

| Command | Runs where | Purpose |
| --- | --- | --- |
| `make selfcheck` | local Linux/WSL host | Validate dependency config, shell syntax, and Makefile wiring. No downloads, no NAS access. |
| `make check` | local host plus SSH to NAS | Verify the installed DSM runtime: module, TTY, NUT processes, DSM services/timers, DSM UPS settings, and live UPS status. |

```sh
make selfcheck
```

```sh
make check
```

Run it after install, after DSM updates, after NAS reboots, and before/after power-loss tests. It confirms that DSM still sees the serial UPS and that the shutdown watchdog is armed before relying on the setup.

The check verifies:

- installed healthcheck result
- CH341 kernel module and `/dev/ttyUSB*`
- NUT driver, server, and monitor processes
- DSM UPS services and timers
- DSM UPS wait time and output-shutdown setting
- live DSM and NUT UPS status

Final success line:

```text
UPS monitoring: PASS
```

### Test

Short detection test:

1. Run `make check`.
2. Cut mains input to the UPS.
3. Wait 2 minutes.
4. Restore mains input.
5. Run `make check` again.

Expected:

- DSM sends a battery-mode notification.
- DSM sends or logs mains-restored status after power returns.
- NAS remains online.

Full shutdown test:

1. Charge the UPS enough for the test.
2. Run `make check`.
3. Cut mains input to the UPS.
4. Wait longer than the configured DSM UPS wait time.
5. DSM enters Safe/Standby Mode.
6. UPS output cuts after the configured off-delay.
7. Restore mains input to the UPS.
8. UPS output returns after the configured on-delay.
9. NAS boots.
10. Run `make check` again.

If the check reports a problem, use [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

`make probe` is a NAS-side diagnostic launched over SSH. Use it for USB/NUT triage, not for local repository checks.
