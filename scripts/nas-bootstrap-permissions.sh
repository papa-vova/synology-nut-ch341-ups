#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[ "$(id -u)" = "0" ] || die "run as root"

install_user="${INSTALL_USER:-${SUDO_USER:-}}"
[ -n "$install_user" ] || die "set INSTALL_USER to the SSH user that will run deploy/check scripts"

case "$install_user" in
  *[!A-Za-z0-9_.@%+-]*) die "INSTALL_USER contains unsupported characters" ;;
esac

id "${install_user#%}" >/dev/null 2>&1 || [ "${install_user#%}" != "$install_user" ] || die "user not found: $install_user"

[ -f /tmp/synology-ch341-ups-install.sh ] || die "/tmp/synology-ch341-ups-install.sh is missing"

install -m 0755 /tmp/synology-ch341-ups-install.sh /usr/local/sbin/synology-ch341-ups-install.sh
mkdir -p /usr/local/lib/modules/ch341-ups
if [ -f /tmp/ch341.ko ]; then
  install -m 0644 /tmp/ch341.ko /usr/local/lib/modules/ch341-ups/ch341.ko
fi

cat > /usr/local/sbin/synology-nut-ch341-apply.sh <<'EOS'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

for arg in "$@"; do
  case "$arg" in
    WAIT_SECONDS=*|UPS_OFF_DELAY_SECONDS=*|UPS_ON_DELAY_SECONDS=*|DOC_USER=*) ;;
    *) echo "ERROR: unsupported argument: $arg" >&2; exit 2 ;;
  esac
done

[ -f /tmp/synology-ch341-ups-install.sh ] && install -m 0755 /tmp/synology-ch341-ups-install.sh /usr/local/sbin/synology-ch341-ups-install.sh
mkdir -p /usr/local/lib/modules/ch341-ups
[ -f /tmp/ch341.ko ] && install -m 0644 /tmp/ch341.ko /usr/local/lib/modules/ch341-ups/ch341.ko
exec env "$@" /usr/local/sbin/synology-ch341-ups-install.sh install
EOS
chmod 0755 /usr/local/sbin/synology-nut-ch341-apply.sh

sudoers=/etc/sudoers.d/synology-nut-ch341-ups
tmp="$sudoers.tmp"
cat > "$tmp" <<EOF2
$install_user ALL=(root) NOPASSWD: /usr/local/sbin/synology-nut-ch341-apply.sh, /usr/local/sbin/synology-nut-ch341-apply.sh *, /usr/local/sbin/synology-ch341-ups-install.sh status, /usr/local/sbin/synology-ch341-ups-install.sh restore, /usr/local/sbin/ch341-ups-healthcheck.sh, /usr/local/sbin/ch341-ups.sh status
EOF2
chmod 0440 "$tmp"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$tmp" >/dev/null
fi
mv "$tmp" "$sudoers"
chmod 0440 "$sudoers"

echo "OK: SSH deploy/check permissions installed for $install_user"
