# Tested Result

Observed working pieces:

- USB device visible as `1a86:7523`.
- `ch341.ko` loaded and created `/dev/ttyUSB0`.
- DSM's stock `nutdrv_qx` read the UPS over `/dev/ttyUSB0` with `protocol = megatec`.
- `/usr/syno/bin/synoups status` returned `OL`.
- DSM Control Panel showed UPS support as enabled with `USB UPS`.
- A short power-loss test produced battery-mode and mains-restored watchdog logs.
- Healthcheck returned `rc=0`.

Important limitation:

- The UPS charge/runtime values are fallback/calibrated values, not trustworthy measured capacity.
- The shutdown policy should be treated as timer-based, not capacity-based.
- UPS output-cut support depends on whether the UPS firmware honors the Megatec/Qx shutdown-return command.
