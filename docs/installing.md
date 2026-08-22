# Installing On DSM

Prerequisites:

- SSH access to the NAS.
- `sudo` or root access.
- A built `ch341.ko` matching the running DSM kernel.
- A UPS visible as CH341 serial USB, usually USB ID `1a86:7523`.

Copy files to the NAS:

```sh
scp scripts/synology-ch341-ups-install.sh .work/out/ch341.ko admin@nas:/tmp/
```

Install:

```sh
ssh admin@nas
sudo -i
/bin/sh /tmp/synology-ch341-ups-install.sh install
```

What the installer writes:

- `/usr/local/lib/modules/ch341-ups/ch341.ko`
- `/usr/local/sbin/ch341-ups.sh`
- `/usr/local/sbin/ch341-ups-healthcheck.sh`
- `/usr/local/sbin/ch341-ups-watchdog.sh`
- `/usr/local/sbin/ch341-upssched-cmd.sh`
- `/usr/local/sbin/ch341-safe-shutdown.sh`
- `ch341-ups.service`
- `ch341-ups-healthcheck.timer`
- `ch341-ups-watchdog.timer`
- DSM `ups-usb.service` drop-in
- DSM `safe-shutdown.service` drop-in
- NUT config under `/etc/ups`

The installer keeps one backup of edited DSM/NUT config files with suffix `.ch341ups-bak`.

Restore stock files:

```sh
/bin/sh /tmp/synology-ch341-ups-install.sh restore
```

## Unattended SSH Install

The first install needs one root-capable action because DSM system files, systemd units, and `/usr/local` paths are modified.

For later unattended installs over SSH, use a fixed root-owned installer path instead of allowing passwordless execution from `/tmp`:

```sh
sudo install -m 0755 /tmp/synology-ch341-ups-install.sh /usr/local/sbin/synology-ch341-ups-install.sh
sudo mkdir -p /usr/local/lib/modules/ch341-ups
sudo install -m 0644 /tmp/ch341.ko /usr/local/lib/modules/ch341-ups/ch341.ko
```

Then create a restricted sudoers file with `visudo`:

```sh
sudo visudo -f /etc/sudoers.d/synology-nut-ch341-ups
```

Example:

```sudoers
admin ALL=(root) NOPASSWD: /usr/local/sbin/synology-ch341-ups-install.sh install, /usr/local/sbin/synology-ch341-ups-install.sh status, /usr/local/sbin/synology-ch341-ups-install.sh restore, /usr/local/sbin/ch341-ups-healthcheck.sh
```

After that, automation can run:

```sh
scp .work/out/ch341.ko admin@nas:/tmp/ch341.ko
ssh admin@nas "sudo install -m 0644 /tmp/ch341.ko /usr/local/lib/modules/ch341-ups/ch341.ko && sudo /usr/local/sbin/synology-ch341-ups-install.sh install"
```

Do not grant `NOPASSWD` for `/bin/sh /tmp/synology-ch341-ups-install.sh`; `/tmp` is writable and that would allow replacement of the script before execution.
