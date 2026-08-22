# Building `ch341.ko`

This project only builds the `ch341` USB serial module. It does not rebuild or replace the DSM kernel.

The tested dependency set is recorded in `config/synology-dependencies.env`:

- Synology GPL kernel source: `linux-4.4.x.txz`
- Synology Gemini Lake toolchain: `geminilake-gcc1220_glibc236_x86_64-GPL.txz`
- Platform config: `synoconfigs/geminilake`

Run:

```sh
./scripts/build-ch341-module.sh
```

The script downloads the Synology archives, verifies SHA-256 checksums, enables `CONFIG_USB_SERIAL_CH341=m`, runs `modules_prepare`, and builds only `drivers/usb/serial/ch341.ko`.

Output:

```text
.work/out/ch341.ko
```

After any DSM update that changes the kernel ABI, rebuild the module and reinstall it. The installed healthcheck compares module `vermagic` with `uname -r` and notifies DSM administrators if the module no longer matches the running kernel.
