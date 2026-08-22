# Synology NUT CH341 UPS

This project makes a Synology DSM NAS work with a USB-attached non-HID UPS that presents as a QinHeng CH340/CH341 serial bridge, commonly visible as USB ID `1a86:7523`.

Problem scope:

- DSM's stock USB UPS detection expects USB HID.
- This UPS is not HID; DSM sees a USB serial bridge, but does not configure it as a UPS.
- There is no off-the-shelf DSM/NUT setup that handles this end-to-end for this device class.
- After mains power is cut, DSM should wait for the configured UPS wait time, enter Safe/Standby Mode, ask the UPS to cut output, and later boot normally when UPS output returns.
- DSM notifications and logs should show whether monitoring is healthy.

The tested device was a Conceptronic UPS exposing USB `1a86:7523` and speaking a Megatec/Qx-style protocol over serial. The tested NAS platform was Synology Gemini Lake with DSM kernel `4.4.302+`.

## Prepare

Set local parameters:

```sh
export DSM_USER=admin
export NAS="$DSM_USER@nas"
export WAIT_SECONDS=900
export UPS_OFF_DELAY_SECONDS=300
export UPS_ON_DELAY_SECONDS=180
```

Verify SSH:

```sh
ssh "$NAS" true
```

DSM settings:

- Control Panel -> Hardware & Power -> General: enable `Restart automatically when power supply issue is fixed`.
- Control Panel -> Notification -> Email: configure email delivery if email alerts are required.

UPS settings after install:

- Control Panel -> Hardware & Power -> UPS -> Enable UPS support: enabled.
- UPS type: `USB UPS`.
- Time before Synology NAS enters Standby Mode: `Customize time`; default install value is 15 minutes.
- `Shut down UPS when the system enters Standby Mode`: checked if the UPS should cut output after DSM enters Safe/Standby Mode.
- `Until low battery`: not recommended for this UPS class because battery/runtime reporting is not reliable enough for the shutdown policy.

The watchdog reads DSM's UPS wait time and UPS-output-shutdown setting at runtime. Changing those two UI settings does not require reinstalling.

## Build

```sh
make build
```

Output:

```text
./.work/out/ch341.ko
```

The build defaults target the tested Gemini Lake DSM kernel. For another platform or source set, override `DSM_PLATFORM`, `KERNEL_SOURCE_URL`, `TOOLCHAIN_URL`, and the matching checksum variables. SHA-256 checks are enabled by default because the build downloads dependencies; set `VERIFY_SHA256=no` only for deliberate experiments.

## Install

Prepare DSM permissions once:

```sh
make bootstrap
```

Install or update the UPS setup:

```sh
make install
```

Override install parameters when needed:

```sh
make install WAIT_SECONDS=900 UPS_OFF_DELAY_SECONDS=300 UPS_ON_DELAY_SECONDS=180
```

## Check

```sh
make check
```

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

## Test

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

## Architecture

The setup stays as close as practical to stock DSM:

- DSM's own `nutdrv_qx`, `upsd`, `upsmon`, `upssched`, and `synoups` are used.
- The added kernel module only creates `/dev/ttyUSB*` for the CH341 bridge.
- A DSM service drop-in points the stock UPS USB service at the serial-aware startup path.
- A watchdog owns the DSM-configured power-loss timer.
- A healthcheck timer verifies the setup after boot and after DSM updates, then notifies DSM administrators if it breaks.

Component sequence:

```mermaid
sequenceDiagram
  autonumber
  participant M as Mains power
  participant U as UPS
  participant N as DSM NUT stack
  participant W as Watchdog
  participant S as DSM Safe Mode
  participant P as NAS power recovery

  M-->>U: power cut
  U-->>N: reports OB or LB through CH341 serial
  N-->>W: status available through upsc
  W->>W: start timer from DSM UPS wait setting
  alt mains returns before timer expires
    U-->>N: reports OL
    W->>W: clear timer
  else timer expires
    W-->>U: request shutdown-return
    W-->>S: request Safe/Standby Mode
    S-->>S: stop services and protect volumes
    U-->>P: cut output after offdelay
    M-->>U: power returns
    U-->>P: restore output after ondelay
    P-->>N: NAS boots
    N-->>W: healthcheck verifies monitoring
  end
```

System state machine:

```mermaid
stateDiagram-v2
  state "Mains powered" as MainsPowered
  state "Battery countdown" as BatteryCountdown
  state "Shutdown requested" as ShutdownRequested
  state "DSM Safe/Standby" as DSMSafeStandby
  state "NAS unpowered" as NASUnpowered
  state "Booting" as Booting

  [*] --> MainsPowered
  MainsPowered --> BatteryCountdown: UPS reports OB or LB
  BatteryCountdown --> MainsPowered: UPS reports OL before DSM wait time
  BatteryCountdown --> ShutdownRequested: DSM wait time expires
  ShutdownRequested --> DSMSafeStandby: DSM accepts Safe/Standby request
  DSMSafeStandby --> NASUnpowered: UPS offdelay expires
  NASUnpowered --> Booting: mains returns and UPS output restores
  Booting --> MainsPowered: healthcheck passes with OL
  Booting --> BatteryCountdown: healthcheck passes with OB or LB
```
