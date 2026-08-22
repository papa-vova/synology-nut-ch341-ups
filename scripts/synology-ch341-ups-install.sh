#!/bin/sh
set -eu

# Public environment:
#   WAIT_SECONDS            Initial DSM UPS wait time written at install.
#   SHUTDOWN_UPS            yes/no default for DSM UPS output shutdown.
#   UPS_OFF_DELAY_SECONDS   NUT offdelay before UPS output cutoff.
#   UPS_ON_DELAY_SECONDS    NUT ondelay before UPS output restore.
#   HEALTH_NOTIFY_OK_ON_BOOT yes/no success notification after first healthy boot check.
#   UPS_NAME                Local NUT UPS name. Default: ups.
#   DOC_USER                DSM user whose home receives the local install note.
#   DOC_FILE_NAME           Install note filename.
#
# Device selection:
#   VID                     USB vendor ID for the serial bridge. Default: 1a86.
#   PID                     USB product ID for the serial bridge. Default: 7523.
#
# Input/output paths:
#   MODULE_SRC              Source ch341.ko path during install. Default: /tmp/ch341.ko.
#   MODULE_DIR              Persistent module directory under /usr/local.
#
# Advanced install path overrides:
#   STACK_SCRIPT, HEALTH_SCRIPT, SAFE_SHUTDOWN_SCRIPT, UPSSCHED_CMD_SCRIPT
#   WATCHDOG_SCRIPT, STACK_UNIT, HEALTH_SERVICE, HEALTH_TIMER
#   WATCHDOG_SERVICE, WATCHDOG_TIMER, SAFE_SHUTDOWN_DROPIN_DIR
#   UPS_USB_DROPIN_DIR, UDEV_RULE
#
# Normal installs should not override advanced paths.

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

MODULE_SRC="${MODULE_SRC:-/tmp/ch341.ko}"
MODULE_DIR="${MODULE_DIR:-/usr/local/lib/modules/ch341-ups}"
MODULE_DST="$MODULE_DIR/ch341.ko"
STACK_SCRIPT="${STACK_SCRIPT:-/usr/local/sbin/ch341-ups.sh}"
HEALTH_SCRIPT="${HEALTH_SCRIPT:-/usr/local/sbin/ch341-ups-healthcheck.sh}"
SAFE_SHUTDOWN_SCRIPT="${SAFE_SHUTDOWN_SCRIPT:-/usr/local/sbin/ch341-safe-shutdown.sh}"
UPSSCHED_CMD_SCRIPT="${UPSSCHED_CMD_SCRIPT:-/usr/local/sbin/ch341-upssched-cmd.sh}"
WATCHDOG_SCRIPT="${WATCHDOG_SCRIPT:-/usr/local/sbin/ch341-ups-watchdog.sh}"
STACK_UNIT="${STACK_UNIT:-/etc/systemd/system/ch341-ups.service}"
HEALTH_SERVICE="${HEALTH_SERVICE:-/etc/systemd/system/ch341-ups-healthcheck.service}"
HEALTH_TIMER="${HEALTH_TIMER:-/etc/systemd/system/ch341-ups-healthcheck.timer}"
WATCHDOG_SERVICE="${WATCHDOG_SERVICE:-/etc/systemd/system/ch341-ups-watchdog.service}"
WATCHDOG_TIMER="${WATCHDOG_TIMER:-/etc/systemd/system/ch341-ups-watchdog.timer}"
SAFE_SHUTDOWN_DROPIN_DIR="${SAFE_SHUTDOWN_DROPIN_DIR:-/etc/systemd/system/safe-shutdown.service.d}"
SAFE_SHUTDOWN_DROPIN="$SAFE_SHUTDOWN_DROPIN_DIR/10-ch341-ups.conf"
UPS_USB_DROPIN_DIR="${UPS_USB_DROPIN_DIR:-/etc/systemd/system/ups-usb.service.d}"
UPS_USB_DROPIN="$UPS_USB_DROPIN_DIR/10-ch341-serial.conf"
UDEV_RULE="${UDEV_RULE:-/etc/udev/rules.d/99-ch341-ups.rules}"
VID="${VID:-1a86}"
PID="${PID:-7523}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
SHUTDOWN_UPS="${SHUTDOWN_UPS:-yes}"
UPS_OFF_DELAY_SECONDS="${UPS_OFF_DELAY_SECONDS:-300}"
UPS_ON_DELAY_SECONDS="${UPS_ON_DELAY_SECONDS:-180}"
HEALTH_NOTIFY_OK_ON_BOOT="${HEALTH_NOTIFY_OK_ON_BOOT:-yes}"
UPS_NAME="${UPS_NAME:-ups}"
DOC_USER="${DOC_USER:-}"
DOC_FILE_NAME="${DOC_FILE_NAME:-synology-ups-ch341-notes.md}"

SYNOUPS_CONF="/usr/syno/etc/ups/synoups.conf"
UPS_CONF="/etc/ups/ups.conf"
UPSD_USERS="/etc/ups/upsd.users"
UPSMON_CONF="/etc/ups/upsmon.conf"
UPSSCHED_CONF="/etc/ups/upssched.conf"
NUTSCAN_USB="/etc/ups/nutscan-usb.h"
BACKUP_SUFFIX=".ch341ups-bak"
LOG_TAG="${LOG_TAG:-ch341-ups}"

log() {
	logger -p user.info -t "$LOG_TAG" "$*" 2>/dev/null || true
	printf '%s\n' "$*" >&2
}

report() {
	if [ "$#" -eq 0 ]; then
		printf '\n'
	else
		printf '%s\n' "$*"
	fi
}

die() {
	logger -p user.err -t "$LOG_TAG" "$*" 2>/dev/null || true
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	[ "$(id -u)" = "0" ] || die "run as root"
}

backup_once() {
	file="$1"
	[ -e "$file" ] || return 0
	if [ ! -e "$file$BACKUP_SUFFIX" ]; then
		cp -p "$file" "$file$BACKUP_SUFFIX"
		log "Backed up $file to $file$BACKUP_SUFFIX"
	fi
}

restore_file() {
	file="$1"
	if [ -e "$file$BACKUP_SUFFIX" ]; then
		cp -p "$file$BACKUP_SUFFIX" "$file"
		log "Restored $file"
	fi
}

install_module() {
	mkdir -p "$MODULE_DIR"
	if [ -f "$MODULE_SRC" ]; then
		cp -p "$MODULE_SRC" "$MODULE_DST"
	elif [ -f "$MODULE_DST" ]; then
		log "Reusing installed module $MODULE_DST"
	else
		die "$MODULE_SRC is missing and $MODULE_DST is not installed"
	fi
	chown root:root "$MODULE_DST" || true
	chmod 644 "$MODULE_DST"
}

write_stack_script() {
	mkdir -p "$(dirname "$STACK_SCRIPT")"
	cat > "$STACK_SCRIPT" <<EOF
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

MODULE_DST="$MODULE_DST"
VID="$VID"
PID="$PID"
WAIT_SECONDS="$WAIT_SECONDS"
SHUTDOWN_UPS="$SHUTDOWN_UPS"
UPS_OFF_DELAY_SECONDS="$UPS_OFF_DELAY_SECONDS"
UPS_ON_DELAY_SECONDS="$UPS_ON_DELAY_SECONDS"
UPS_NAME="$UPS_NAME"
UPSSCHED_CMD_SCRIPT="$UPSSCHED_CMD_SCRIPT"
SYNOUPS_CONF="$SYNOUPS_CONF"
UPS_CONF="$UPS_CONF"
UPSD_USERS="$UPSD_USERS"
NUTSCAN_USB="$NUTSCAN_USB"
BACKUP_SUFFIX="$BACKUP_SUFFIX"
LOG_TAG="$LOG_TAG"

log() {
	logger -p user.info -t "\$LOG_TAG" "\$*" 2>/dev/null || true
	printf '%s\n' "\$*" >&2
}

report() {
	if [ "\$#" -eq 0 ]; then
		printf '\n'
	else
		printf '%s\n' "\$*"
	fi
}

die() {
	logger -p user.err -t "\$LOG_TAG" "\$*" 2>/dev/null || true
	printf 'ERROR: %s\n' "\$*" >&2
	exit 1
}

backup_once() {
	file="\$1"
	[ -e "\$file" ] || return 0
	if [ ! -e "\$file\$BACKUP_SUFFIX" ]; then
		cp -p "\$file" "\$file\$BACKUP_SUFFIX"
		log "Backed up \$file to \$file\$BACKUP_SUFFIX"
	fi
}

load_module() {
	if ! lsmod | grep -q '^usbserial '; then
		[ -f /lib/modules/usbserial.ko ] || die "/lib/modules/usbserial.ko is missing"
		insmod /lib/modules/usbserial.ko || true
	fi
	if ! lsmod | grep -q '^ch341 '; then
		[ -f "\$MODULE_DST" ] || die "\$MODULE_DST is missing"
		insmod "\$MODULE_DST"
	fi
}

find_ch341_tty() {
	for tty_path in /sys/class/tty/ttyUSB*; do
		[ -e "\$tty_path" ] || continue
		dev_path="\$(readlink -f "\$tty_path/device" 2>/dev/null || true)"
		[ -n "\$dev_path" ] || continue
		cur="\$dev_path"
		while [ "\$cur" != "/" ] && [ "\$cur" != "." ]; do
			if [ -f "\$cur/idVendor" ] && [ -f "\$cur/idProduct" ]; then
				vendor="\$(tr 'A-F' 'a-f' < "\$cur/idVendor" 2>/dev/null || true)"
				product="\$(tr 'A-F' 'a-f' < "\$cur/idProduct" 2>/dev/null || true)"
				if [ "\$vendor" = "\$VID" ] && [ "\$product" = "\$PID" ]; then
					printf '/dev/%s\n' "\$(basename "\$tty_path")"
					return 0
				fi
			fi
			cur="\$(dirname "\$cur")"
		done
	done
	return 1
}

ensure_scan_entry() {
	[ -f "\$NUTSCAN_USB" ] || die "\$NUTSCAN_USB is missing"
	backup_once "\$NUTSCAN_USB"
	tmp="/tmp/ch341-ups-nutscan.\$\$"
	printf '{ 0x%s, 0x%s, "nutdrv_qx" }\n' "\$VID" "\$PID" > "\$tmp"
	grep -vi "0x\$VID, 0x\$PID" "\$NUTSCAN_USB" >> "\$tmp" || true
	cp "\$tmp" "\$NUTSCAN_USB"
	rm -f "\$tmp"
	chown root:root "\$NUTSCAN_USB" || true
	chmod 640 "\$NUTSCAN_USB" || true
}

write_ups_conf() {
	tty_dev="\$1"
	backup_once "\$UPS_CONF"
	{
		printf '[%s]\n' "\$UPS_NAME"
		printf '\tdriver = nutdrv_qx\n'
		printf '\tport = %s\n' "\$tty_dev"
		printf '\tprotocol = megatec\n'
		printf '\toffdelay = %s\n' "\$UPS_OFF_DELAY_SECONDS"
		printf '\tondelay = %s\n' "\$UPS_ON_DELAY_SECONDS"
		printf '\tnovendor\n'
		printf '\tnorating\n'
		printf '\tuser = root\n'
		printf '\tdefault.device.mfr = Conceptronic\n'
		printf '\tdefault.device.model = CH341 serial UPS\n'
		printf '\tdefault.ups.mfr = Conceptronic\n'
		printf '\tdefault.ups.model = CH341 serial UPS\n'
		printf '\tdefault.input.voltage.nominal = 230\n'
		printf '\tdefault.output.voltage.nominal = 230\n'
		printf '\tdefault.input.frequency.nominal = 50\n'
		printf '\tdefault.battery.voltage.nominal = 12\n'
		printf '\tdefault.battery.voltage.low = 10.50\n'
		printf '\tdefault.battery.voltage.high = 13.70\n'
		printf '\tdefault.battery.packs = 1\n'
		printf '\toverride.battery.packs = 1\n'
		printf '\tdefault.battery.charge.low = 20\n'
		printf '\tdefault.battery.runtime = %s\n' "\$WAIT_SECONDS"
		printf '\tdefault.battery.runtime.low = 300\n'
		printf '\truntimecal = 900,20,3600,10\n'
		printf '\tchargetime = 43200\n'
		printf '\tidleload = 10\n'
		printf '\tdesc = "Conceptronic UPS via CH341"\n'
	} > "\$UPS_CONF"
	chown root:root "\$UPS_CONF" || true
	chmod 640 "\$UPS_CONF" || true
}

set_or_append_monitor() {
	file="\$1"
	line="\$2"
	if grep -q '^MONITOR ' "\$file" 2>/dev/null; then
		sed -i "s|^MONITOR .*|\$line|" "\$file"
	else
		printf '%s\n' "\$line" >> "\$file"
	fi
}

set_or_append_directive() {
	file="\$1"
	key="\$2"
	value="\$3"
	if grep -q "^\$key[[:space:]]" "\$file" 2>/dev/null; then
		sed -i "s|^\$key[[:space:]].*|\$key \$value|" "\$file"
	else
		printf '%s %s\n' "\$key" "\$value" >> "\$file"
	fi
}

configure_stock_nut_files() {
	backup_once "$UPSD_USERS"
	backup_once "$UPSMON_CONF"
	backup_once "$UPSSCHED_CONF"
	cat > "$UPSD_USERS" <<'EOU'
[monuser]
	password = secret
	upsmon master
EOU
	[ -s "$UPSMON_CONF" ] || cp -p /etc.defaults/ups/upsmon.conf "$UPSMON_CONF"
	[ -s "$UPSSCHED_CONF" ] || cp -p /etc.defaults/ups/upssched.conf "$UPSSCHED_CONF"
	set_or_append_monitor "$UPSMON_CONF" "MONITOR \$UPS_NAME@localhost 1 monuser secret master"
	sed -i "/^NOTIFYCMD /d; /^NOTIFYFLAG ONBATT /d; /^NOTIFYFLAG ONLINE /d; /^NOTIFYFLAG LOWBATT /d; /^NOTIFYFLAG FSD /d" "$UPSMON_CONF"
	printf 'NOTIFYCMD /usr/sbin/upssched\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG FSD SYSLOG+WALL+EXEC\n' >> "$UPSMON_CONF"
	set_or_append_directive "$UPSSCHED_CONF" "CMDSCRIPT" "\$UPSSCHED_CMD_SCRIPT"
	sed -i "/^AT ONBATT/d; /^AT ONLINE/d" "$UPSSCHED_CONF"
	printf 'AT ONBATT * EXECUTE onbatt\n' >> "$UPSSCHED_CONF"
	printf 'AT ONLINE * EXECUTE online\n' >> "$UPSSCHED_CONF"
	chown root:root "$UPSD_USERS" "$UPSMON_CONF" "$UPSSCHED_CONF" || true
	chmod 640 "$UPSD_USERS" "$UPSMON_CONF" "$UPSSCHED_CONF" || true
}

configure_synology() {
	mkdir -p "\$(dirname "\$SYNOUPS_CONF")"
	[ -e "\$SYNOUPS_CONF" ] || : > "\$SYNOUPS_CONF"
	chown root:root "\$SYNOUPS_CONF" || true
	chmod 640 "\$SYNOUPS_CONF" || true
	backup_once "\$SYNOUPS_CONF"
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_enabled yes
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" upsslave_enabled no
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_mode usb
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_wait_time "\$WAIT_SECONDS"
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown "\$SHUTDOWN_UPS"
}

start_stack() {
	load_module
	tty_dev="\$(find_ch341_tty || true)"
	[ -n "\$tty_dev" ] || die "CH341 USB serial device \$VID:\$PID did not appear as /dev/ttyUSB*"
	ensure_scan_entry
	write_ups_conf "\$tty_dev"
	configure_synology
	configure_stock_nut_files
	mkdir -p /run/ups_state /tmp/ups
	systemctl stop ups-net.service >/dev/null 2>&1 || true
	/usr/syno/lib/systemd/scripts/ups-usb.sh stop >/dev/null 2>&1 || true
	/usr/syno/bin/synosetkeyvalue /tmp/ups/ups.info upsmaster yes || true
	printf 'nutdrv_qx\n' > /tmp/ups/ups_drv.curr
	rm -f /run/ups_state/upsd.pid /run/upsmon.pid /run/ups_state/nutdrv_qx-ups /run/ups_state/nutdrv_qx-ups.pid 2>/dev/null || true
	/usr/bin/upsdrvctl -u root start
	sleep 1
	/usr/sbin/upsd
	sleep 1
	/usr/sbin/upsmon
	i=0
	while [ "\$i" -lt 20 ]; do
		if /usr/bin/upsc "\$UPS_NAME@localhost" ups.status >/dev/null 2>&1; then
			log "Synology UPS USB service is reading \$UPS_NAME@localhost via \$tty_dev"
			return 0
		fi
		i=\$((i + 1))
		sleep 1
	done
	/usr/bin/upsc "\$UPS_NAME@localhost" 2>&1 || true
	ps aux | grep -E 'nutdrv_qx|upsd|upsmon|upssched' | grep -v grep || true
	die "Synology UPS USB service started but \$UPS_NAME@localhost is not readable"
}

stop_stack() {
	/usr/syno/lib/systemd/scripts/ups-usb.sh stop >/dev/null 2>&1 || true
}

status_stack() {
	report "Kernel modules:"
	lsmod | grep -E "^(ch341|usbserial)" || true
	report
	report "TTY:"
	find_ch341_tty || true
	ls -l /dev/ttyUSB* 2>/dev/null || true
	report
	report "Processes:"
	ps aux | grep -E 'nutdrv_qx|upsd|upsmon|upssched' | grep -v grep || true
	report
	report "UPS status:"
	/usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>&1 || true
	/usr/bin/upsc "\$UPS_NAME@localhost" input.voltage 2>/dev/null || true
	/usr/bin/upsc "\$UPS_NAME@localhost" battery.voltage 2>/dev/null || true
	/usr/bin/upsc "\$UPS_NAME@localhost" battery.charge 2>/dev/null || true
	/usr/bin/upsc "\$UPS_NAME@localhost" battery.runtime 2>/dev/null || true
	/usr/bin/upsc "\$UPS_NAME@localhost" device.mfr 2>/dev/null || true
	/usr/bin/upsc "\$UPS_NAME@localhost" device.model 2>/dev/null || true
	report
	report "Synology config:"
	grep -E "^(ups_enabled|upsslave_enabled|ups_mode|ups_wait_time|ups_safeshutdown)=" "\$SYNOUPS_CONF" || true
}

case "\${1:-start}" in
	start)
		start_stack
		;;
	stop)
		stop_stack
		;;
	restart)
		stop_stack
		start_stack
		;;
	status)
		status_stack
		;;
	*)
		printf 'Usage: %s {start|stop|restart|status}\n' "\$0" >&2
		exit 2
		;;
esac
EOF
	chown root:root "$STACK_SCRIPT" || true
	chmod 755 "$STACK_SCRIPT"
}

write_stack_unit() {
	mkdir -p "$(dirname "$STACK_UNIT")"
	cat > "$STACK_UNIT" <<EOF
[Unit]
Description=CH341 serial UPS boot trigger
After=syno-bootup-done.target
Wants=syno-bootup-done.target
IgnoreOnIsolate=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/systemctl restart ups-usb.service
ExecStop=/bin/systemctl stop ups-usb.service

[Install]
WantedBy=syno-bootup-done.target
EOF
	chown root:root "$STACK_UNIT" || true
	chmod 644 "$STACK_UNIT"
}

write_ups_usb_dropin() {
	mkdir -p "$UPS_USB_DROPIN_DIR"
	cat > "$UPS_USB_DROPIN" <<EOF
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=
ExecStart=$STACK_SCRIPT start
ExecStop=
ExecStop=$STACK_SCRIPT stop
ExecReload=
ExecReload=$STACK_SCRIPT restart
EOF
	chown root:root "$UPS_USB_DROPIN" || true
	chmod 644 "$UPS_USB_DROPIN"
}

write_udev_rule() {
	mkdir -p "$(dirname "$UDEV_RULE")"
	cat > "$UDEV_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyUSB*", ATTRS{idVendor}=="$VID", ATTRS{idProduct}=="$PID", RUN+="/bin/systemctl restart ups-usb.service"
EOF
	chown root:root "$UDEV_RULE" || true
	chmod 644 "$UDEV_RULE"
	udevadm control --reload-rules >/dev/null 2>&1 || true
}

write_upssched_cmd_script() {
	mkdir -p "$(dirname "$UPSSCHED_CMD_SCRIPT")"
	cat > "$UPSSCHED_CMD_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

STACK_SCRIPT="$STACK_SCRIPT"
UPS_NAME="$UPS_NAME"
SYNOUPS_CONF="$SYNOUPS_CONF"
SYNOUPS="/usr/syno/bin/synoups"
BATTERY_NOTIFY="/usr/syno/bin/synoups_battery_notify.sh"
LOG_TAG="ch341-ups"
SHUTDOWN_SENT="/run/ch341-ups-shutdown-return.sent"

log() {
	logger -p user.err -t "\$LOG_TAG" "\$*"
}

pass_to_synology() {
	"\$SYNOUPS" "\$1" || log "Synology UPS command failed: \$1"
}

is_on_battery() {
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	case "\$status" in
		*OB*|*LB*)
			return 0
			;;
	esac
	log "Skipping final UPS shutdown action because current UPS status is: \${status:-empty}"
	return 1
}

ups_output_shutdown_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

schedule_ups_output_cut() {
	if [ -e "\$SHUTDOWN_SENT" ]; then
		log "UPS shutdown-return already requested; skipping duplicate request"
		return 0
	fi
	touch "\$SHUTDOWN_SENT"
	log "Scheduling UPS shutdown-return before DSM enters Safe Mode"
	"\$STACK_SCRIPT" start || log "Could not refresh serial UPS stack before shutdown-return command"
	if ups_output_shutdown_enabled; then
		if /usr/bin/timeout 25 "\$SYNOUPS" shutdownups; then
			log "Synology UPS shutdown-return command completed"
			return 0
		fi
		log "Synology UPS shutdown-return command failed; trying upsdrvctl shutdown fallback"
		/usr/bin/timeout 25 /usr/bin/upsdrvctl -u root shutdown || log "upsdrvctl shutdown fallback failed"
	fi
}

case "\${1:-}" in
	onbatt)
		if [ -x "\$BATTERY_NOTIFY" ]; then
			"\$BATTERY_NOTIFY" || log "Battery notification script failed"
		else
			pass_to_synology onbatt
		fi
		;;
	online|nocomm|fsd)
		[ "\$1" = "online" ] && rm -f "\$SHUTDOWN_SENT"
		pass_to_synology "\$1"
		;;
	lowbatt)
		pass_to_synology lowbatt
		;;
	waittimeup)
		if is_on_battery; then
			schedule_ups_output_cut
			pass_to_synology lowbatt
		fi
		;;
	*)
		log "Unknown UPS scheduler command: \${1:-empty}"
		pass_to_synology "\${1:-}"
		;;
esac
EOF
	chown root:root "$UPSSCHED_CMD_SCRIPT" || true
	chmod 755 "$UPSSCHED_CMD_SCRIPT"
}

write_watchdog_script() {
	mkdir -p "$(dirname "$WATCHDOG_SCRIPT")"
	cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

STACK_SCRIPT="$STACK_SCRIPT"
UPS_NAME="$UPS_NAME"
DEFAULT_WAIT_SECONDS="$WAIT_SECONDS"
SYNOUPS_CONF="$SYNOUPS_CONF"
SYNOUPS="/usr/syno/bin/synoups"
STATE_DIR="/run/ch341-ups-watchdog"
ONBATT_STAMP="\$STATE_DIR/onbattery.since"
SHUTDOWN_SENT="/run/ch341-ups-shutdown-return.sent"
LOG_TAG="ch341-ups"

log() {
	logger -p user.err -t "\$LOG_TAG" "\$*"
}

configured_wait_seconds() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_wait_time 2>/dev/null || true)"
	case "\$value" in
		""|*[!0-9]*)
			printf "%s\\n" "\$DEFAULT_WAIT_SECONDS"
			;;
		*)
			printf "%s\\n" "\$value"
			;;
	esac
}

ups_support_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_enabled 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

ups_output_shutdown_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

mkdir -p "\$STATE_DIR"

status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
now="\$(date +%s)"

if ! ups_support_enabled; then
	log "DSM UPS support is disabled; watchdog inactive"
	rm -f "\$ONBATT_STAMP" "\$SHUTDOWN_SENT"
	exit 0
fi

case "\$status" in
	*OB*|*LB*)
		if [ ! -f "\$ONBATT_STAMP" ]; then
			printf '%s\n' "\$now" > "\$ONBATT_STAMP"
			log "UPS watchdog saw battery mode: \$status"
			exit 0
		fi
		;;
	*OL*)
		if [ -f "\$ONBATT_STAMP" ] || [ -f "\$SHUTDOWN_SENT" ]; then
			log "UPS watchdog saw mains restored: \$status"
		fi
		rm -f "\$ONBATT_STAMP" "\$SHUTDOWN_SENT"
		exit 0
		;;
	*)
		log "UPS watchdog could not read valid UPS status: \${status:-empty}"
		exit 1
		;;
esac

since="\$now"
if [ -f "\$ONBATT_STAMP" ]; then
	since="\$(cat "\$ONBATT_STAMP" 2>/dev/null || true)"
	[ -n "\$since" ] || since="\$now"
fi
elapsed=\$((now - since))

wait_seconds="\$(configured_wait_seconds)"
if [ "\$elapsed" -lt "\$wait_seconds" ]; then
	exit 0
fi

if [ -e "\$SHUTDOWN_SENT" ]; then
	exit 0
fi

touch "\$SHUTDOWN_SENT"
log "UPS watchdog battery timer reached \${elapsed}s (configured wait \${wait_seconds}s); scheduling UPS shutdown-return and DSM Safe Mode"

"\$STACK_SCRIPT" start || log "UPS watchdog could not refresh serial UPS stack before shutdown-return command"

if ups_output_shutdown_enabled; then
	if /usr/bin/timeout 25 "\$SYNOUPS" shutdownups; then
		log "UPS watchdog: Synology UPS shutdown-return command completed"
	else
		log "UPS watchdog: Synology UPS shutdown-return failed; trying upsdrvctl shutdown fallback"
		/usr/bin/timeout 25 /usr/bin/upsdrvctl -u root shutdown || log "UPS watchdog: upsdrvctl shutdown fallback failed"
	fi
else
	log "DSM UPS output shutdown is disabled; skipping UPS output cut"
fi

"\$SYNOUPS" lowbatt || log "UPS watchdog: Synology lowbatt Safe Mode command failed"
EOF
	chown root:root "$WATCHDOG_SCRIPT" || true
	chmod 755 "$WATCHDOG_SCRIPT"
}

write_watchdog_units() {
	mkdir -p "$(dirname "$WATCHDOG_SERVICE")" "$(dirname "$WATCHDOG_TIMER")"
	cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=CH341 UPS battery-mode watchdog
After=syno-bootup-done.target ch341-ups.service
Wants=ch341-ups.service

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF
	chown root:root "$WATCHDOG_SERVICE" || true
	chmod 644 "$WATCHDOG_SERVICE"

	cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Run CH341 UPS battery-mode watchdog

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=ch341-ups-watchdog.service

[Install]
WantedBy=timers.target
EOF
	chown root:root "$WATCHDOG_TIMER" || true
	chmod 644 "$WATCHDOG_TIMER"
}

write_health_script() {
	mkdir -p "$(dirname "$HEALTH_SCRIPT")"
	cat > "$HEALTH_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

MODULE_DST="$MODULE_DST"
STACK_SCRIPT="$STACK_SCRIPT"
UPS_NAME="$UPS_NAME"
WAIT_SECONDS="$WAIT_SECONDS"
SHUTDOWN_UPS="$SHUTDOWN_UPS"
HEALTH_NOTIFY_OK_ON_BOOT_DEFAULT="$HEALTH_NOTIFY_OK_ON_BOOT"
STACK_UNIT="$STACK_UNIT"
HEALTH_TIMER="$HEALTH_TIMER"
STACK_UNIT_NAME="$(basename "$STACK_UNIT")"
HEALTH_TIMER_NAME="$(basename "$HEALTH_TIMER")"
WATCHDOG_SCRIPT="$WATCHDOG_SCRIPT"
WATCHDOG_TIMER="$WATCHDOG_TIMER"
WATCHDOG_TIMER_NAME="$(basename "$WATCHDOG_TIMER")"
UPS_USB_DROPIN="$UPS_USB_DROPIN"
SAFE_SHUTDOWN_SCRIPT="$SAFE_SHUTDOWN_SCRIPT"
SAFE_SHUTDOWN_DROPIN="$SAFE_SHUTDOWN_DROPIN"
UPSSCHED_CMD_SCRIPT="$UPSSCHED_CMD_SCRIPT"
UPSSCHED_CONF="$UPSSCHED_CONF"
UPSMON_CONF="$UPSMON_CONF"
SYNOUPS_CONF="$SYNOUPS_CONF"
FAIL_STAMP="/run/ch341-ups-health.failed"
LAST_NOTIFY="/run/ch341-ups-health.last-notify"
BOOT_OK_STAMP="/run/ch341-ups-health.boot-ok-notified"
NOTIFY_INTERVAL_SECONDS=21600
HEALTH_NOTIFY_OK_ON_BOOT="\${HEALTH_NOTIFY_OK_ON_BOOT:-\$HEALTH_NOTIFY_OK_ON_BOOT_DEFAULT}"

issues=""

log() {
	logger -p user.info -t ch341-ups "\$*"
}

append_issue() {
	if [ -z "\$issues" ]; then
		issues="\$1"
	else
		issues="\$issues; \$1"
	fi
}

notify_admins() {
	title="\$1"
	message="\$2"
	logger -p user.err -t ch341-ups "\$title: \$message"
	if [ -x /usr/syno/bin/synodsmnotify ]; then
		/usr/syno/bin/synodsmnotify -e true -b true -l warn @administrators "\$title" "\$message" >/dev/null 2>&1 || \\
			/usr/syno/bin/synodsmnotify @administrators "\$title" "\$message" >/dev/null 2>&1 || true
	fi
}

notify_admins_info() {
	title="\$1"
	message="\$2"
	logger -p user.info -t ch341-ups "\$title: \$message"
	if [ -x /usr/syno/bin/synodsmnotify ]; then
		/usr/syno/bin/synodsmnotify -e true -b true -l info @administrators "\$title" "\$message" >/dev/null 2>&1 || \\
			/usr/syno/bin/synodsmnotify @administrators "\$title" "\$message" >/dev/null 2>&1 || true
	fi
}

ups_support_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_enabled 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

notify_boot_ok() {
	[ "\${CH341_HEALTHCHECK_TIMER:-}" = "yes" ] || return 0
	[ "\$HEALTH_NOTIFY_OK_ON_BOOT" = "yes" ] || return 0
	[ -e "\$BOOT_OK_STAMP" ] && return 0
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || printf '%s\n' unknown)"
	wait="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_wait_time 2>/dev/null || true)"
	safe="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	notify_admins_info "UPS monitoring healthy on \$(hostname)" "UPS status is \${status:-unknown}. DSM wait time is \${wait:-unknown}s. UPS output shutdown is \${safe:-unknown}."
	touch "\$BOOT_OK_STAMP"
}

module_vermagic() {
	[ -f "\$MODULE_DST" ] || return 1
	/bin/grep -ao 'vermagic=[^[:space:]]*' "\$MODULE_DST" 2>/dev/null | awk -F= 'NR == 1 {print \$2}'
}

valid_ups_status() {
	case "\$1" in
		OL*|OB*|LB*)
			return 0
			;;
	esac
	return 1
}

check_once() {
	issues=""
	kernel="\$(uname -r)"
	if [ -f "\$MODULE_DST" ]; then
		vermagic="\$(module_vermagic || true)"
		if [ -n "\$vermagic" ] && [ "\$vermagic" != "\$kernel" ]; then
			append_issue "ch341.ko vermagic \$vermagic does not match running kernel \$kernel"
		fi
	else
		append_issue "\$MODULE_DST is missing"
	fi
	[ -x "\$STACK_SCRIPT" ] || append_issue "\$STACK_SCRIPT is missing or not executable"
	[ -x "\$SAFE_SHUTDOWN_SCRIPT" ] || append_issue "\$SAFE_SHUTDOWN_SCRIPT is missing or not executable"
	[ -x "\$UPSSCHED_CMD_SCRIPT" ] || append_issue "\$UPSSCHED_CMD_SCRIPT is missing or not executable"
	[ -x "\$WATCHDOG_SCRIPT" ] || append_issue "\$WATCHDOG_SCRIPT is missing or not executable"
	[ -f "\$UPS_USB_DROPIN" ] || append_issue "\$UPS_USB_DROPIN is missing"
	[ -f "\$SAFE_SHUTDOWN_DROPIN" ] || append_issue "\$SAFE_SHUTDOWN_DROPIN is missing"
	systemctl is-enabled --quiet "\$STACK_UNIT_NAME" || append_issue "\$STACK_UNIT_NAME is not enabled"
	systemctl is-enabled --quiet "\$HEALTH_TIMER_NAME" || append_issue "\$HEALTH_TIMER_NAME is not enabled"
	systemctl is-enabled --quiet "\$WATCHDOG_TIMER_NAME" || append_issue "\$WATCHDOG_TIMER_NAME is not enabled"
	systemctl is-active --quiet "\$WATCHDOG_TIMER_NAME" || append_issue "\$WATCHDOG_TIMER_NAME is not active"
	systemctl cat ups-usb.service 2>/dev/null | grep -Fq "ExecStart=\$STACK_SCRIPT start" || append_issue "ups-usb.service is not using \$STACK_SCRIPT"
	systemctl cat safe-shutdown.service 2>/dev/null | grep -Fq "ExecStart=\$SAFE_SHUTDOWN_SCRIPT" || append_issue "safe-shutdown.service is not using \$SAFE_SHUTDOWN_SCRIPT"
	grep -Fq "NOTIFYCMD /usr/sbin/upssched" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon is not configured to invoke upssched"
	grep -Fq "NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon ONBATT notification does not execute commands"
	grep -Fq "CMDSCRIPT \$UPSSCHED_CMD_SCRIPT" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched is not using \$UPSSCHED_CMD_SCRIPT"
	conf_enabled="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_enabled 2>/dev/null || true)"
	[ "\$conf_enabled" = "yes" ] || append_issue "DSM UPS support is \${conf_enabled:-empty}, expected yes"
	conf_mode="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_mode 2>/dev/null || true)"
	[ "\$conf_mode" = "usb" ] || append_issue "DSM UPS mode is \${conf_mode:-empty}, expected usb"
	conf_wait="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_wait_time 2>/dev/null || true)"
	case "\$conf_wait" in
		""|*[!0-9]*) append_issue "DSM UPS wait time is not numeric: \${conf_wait:-empty}" ;;
	esac
	conf_safe="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	case "\$conf_safe" in
		yes|no) ;;
		*) append_issue "DSM UPS output-shutdown flag is not yes/no: \${conf_safe:-empty}" ;;
	esac
	lsmod | grep -q '^ch341 ' || append_issue "ch341 module is not loaded"
	ls /dev/ttyUSB* >/dev/null 2>&1 || append_issue "no /dev/ttyUSB* device exists"
	systemctl is-active --quiet ups-usb.service || append_issue "ups-usb.service is not active"
	ps aux | grep -v grep | grep -q 'nutdrv_qx' || append_issue "nutdrv_qx is not running"
	ps aux | grep -v grep | grep -q '/usr/sbin/upsd' || append_issue "upsd is not running"
	ps aux | grep -v grep | grep -q '/usr/sbin/upsmon' || append_issue "upsmon is not running"
	ups_status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	if ! valid_ups_status "\$ups_status"; then
		append_issue "upsc \$UPS_NAME@localhost failed or returned invalid status: \${ups_status:-empty}"
	fi
	driver_port="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" driver.parameter.port 2>/dev/null || true)"
	case "\$driver_port" in
		/dev/ttyUSB*) ;;
		*) append_issue "UPS driver port is \${driver_port:-empty}, expected /dev/ttyUSB*" ;;
	esac
	[ -z "\$issues" ]
}

if check_once; then
	if [ -e "\$FAIL_STAMP" ]; then
		notify_admins "UPS monitoring recovered on \$(hostname)" "UPS status is \$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || printf '%s\n' unknown)."
	fi
	notify_boot_ok
	rm -f "\$FAIL_STAMP" "\$LAST_NOTIFY"
	exit 0
fi

first_issues="\$issues"

systemctl restart ch341-ups.service >/dev/null 2>&1 || true
sleep 8

if check_once; then
	if [ -e "\$FAIL_STAMP" ]; then
		notify_admins "UPS monitoring recovered on \$(hostname)" "UPS status is \$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || printf '%s\n' unknown)."
	fi
	notify_boot_ok
	rm -f "\$FAIL_STAMP" "\$LAST_NOTIFY"
	exit 0
fi

now="\$(date +%s)"

if ! ups_support_enabled; then
	log "DSM UPS support is disabled; watchdog inactive"
	exit 0
fi
last="0"
if [ -f "\$LAST_NOTIFY" ]; then
	last="\$(cat "\$LAST_NOTIFY" 2>/dev/null || true)"
	[ -n "\$last" ] || last="0"
fi
age=\$((now - last))

if [ ! -e "\$FAIL_STAMP" ] || [ "\$age" -ge "\$NOTIFY_INTERVAL_SECONDS" ]; then
	message="UPS monitoring is not healthy on \$(hostname). Current issue: \$issues. Before automatic restart: \$first_issues. If this began after a DSM update and a vermagic mismatch is reported, rebuild ch341.ko for the new DSM kernel. Check \\\`systemctl status ch341-ups.service\\\` and \\\`$STACK_SCRIPT status\\\`."
	notify_admins "UPS monitoring problem on \$(hostname)" "\$message"
	printf '%s\n' "\$now" > "\$LAST_NOTIFY"
	touch "\$FAIL_STAMP"
fi

exit 1
EOF
	chown root:root "$HEALTH_SCRIPT" || true
	chmod 755 "$HEALTH_SCRIPT"
}

write_health_units() {
	mkdir -p "$(dirname "$HEALTH_SERVICE")" "$(dirname "$HEALTH_TIMER")"
	cat > "$HEALTH_SERVICE" <<EOF
[Unit]
Description=Check CH341 Synology UPS monitoring
After=syno-bootup-done.target ch341-ups.service
Wants=ch341-ups.service

[Service]
Type=oneshot
Environment=CH341_HEALTHCHECK_TIMER=yes
ExecStart=$HEALTH_SCRIPT
EOF
	chown root:root "$HEALTH_SERVICE" || true
	chmod 644 "$HEALTH_SERVICE"

	cat > "$HEALTH_TIMER" <<EOF
[Unit]
Description=Periodic CH341 Synology UPS monitoring check

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true
Unit=ch341-ups-healthcheck.service

[Install]
WantedBy=timers.target
EOF
	chown root:root "$HEALTH_TIMER" || true
	chmod 644 "$HEALTH_TIMER"
}

write_safe_shutdown_script() {
	mkdir -p "$(dirname "$SAFE_SHUTDOWN_SCRIPT")"
	cat > "$SAFE_SHUTDOWN_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

SYNOUPS_CONF="$SYNOUPS_CONF"
STACK_SCRIPT="$STACK_SCRIPT"

logger -p user.err -t ch341-ups "Safe shutdown started; preparing serial UPS shutdown-return path"

/bin/umount / >/dev/null 2>&1 || true

UpsMode="\$(/bin/get_key_value "\$SYNOUPS_CONF" ups_mode 2>/dev/null || true)"
[ -n "\$UpsMode" ] || UpsMode="usb"

if [ "\$UpsMode" = "usb" ]; then
	"\$STACK_SCRIPT" start || logger -p user.err -t ch341-ups "Could not restart serial UPS stack during safe shutdown"
elif [ "\$UpsMode" = "snmp" ] || [ "\$UpsMode" = "slave" ]; then
	/usr/syno/lib/systemd/scripts/ups-net.sh start
fi

/usr/syno/bin/scemd &
sleep 2

logger -p user.err -t ch341-ups "Calling Synology UPS output shutdown command"
/usr/syno/bin/synoups shutdownups
EOF
	chown root:root "$SAFE_SHUTDOWN_SCRIPT" || true
	chmod 755 "$SAFE_SHUTDOWN_SCRIPT"
}

write_safe_shutdown_dropin() {
	mkdir -p "$SAFE_SHUTDOWN_DROPIN_DIR"
	cat > "$SAFE_SHUTDOWN_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=$SAFE_SHUTDOWN_SCRIPT
EOF
	chown root:root "$SAFE_SHUTDOWN_DROPIN" || true
	chmod 644 "$SAFE_SHUTDOWN_DROPIN"
}

configure_synology_files() {
	"$STACK_SCRIPT" start
}

verify_all() {
	log
	log "Verification:"
	"$STACK_SCRIPT" status || true
	log
	systemctl is-active ch341-ups.service || true
	systemctl is-active ups-usb.service || true
	systemctl is-active ch341-ups-healthcheck.timer || true
	systemctl is-active ch341-ups-watchdog.timer || true
	systemctl is-enabled ch341-ups.service || true
	systemctl is-enabled ch341-ups-healthcheck.timer || true
	systemctl is-enabled ch341-ups-watchdog.timer || true
	log
	systemctl cat safe-shutdown.service | sed -n '1,90p' || true
	log
	grep '^MONITOR ' "$UPSMON_CONF" || true
	grep -E '^NOTIFYCMD|^NOTIFYFLAG ONBATT|^NOTIFYFLAG ONLINE' "$UPSMON_CONF" || true
	grep -E '^CMDSCRIPT|^AT ONLINE' "$UPSSCHED_CONF" || true
	grep -E '^AT ONBATT .*onbatt' "$UPSSCHED_CONF" || true
	log
	systemctl list-timers ch341-ups-healthcheck.timer --no-pager || true
	systemctl list-timers ch341-ups-watchdog.timer --no-pager || true
}

doc_home() {
	[ -n "$DOC_USER" ] || return 1
	home="$(awk -F: -v u="$DOC_USER" '$1 == u {print $6}' /etc/passwd 2>/dev/null || true)"
	if [ -n "$home" ] && [ -d "$home" ]; then
		printf '%s\n' "$home"
		return 0
	fi
	for candidate in "/var/services/homes/$DOC_USER" "/volume1/homes/$DOC_USER" "/home/$DOC_USER"; do
		if [ -d "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

write_doc() {
	home="$(doc_home || true)"
	[ -n "$home" ] || {
		log "DOC_USER is unset or not found; skipped markdown note"
		return 0
	}
	doc="$home/$DOC_FILE_NAME"
	cat > "$doc" <<EOF
# Synology UPS CH341 Setup

Date: $(date '+%Y-%m-%d %H:%M:%S %Z')
NAS kernel: $(uname -a)

## What was found

- The UPS USB device presents as \`$VID:$PID\`, a QinHeng CH340/CH341 USB-to-serial bridge.
- DSM's normal USB HID UPS path did not detect it.
- A single matching kernel module, \`ch341.ko\`, was built for \`4.4.302+\` and tested with \`insmod\`.
- Loading \`ch341.ko\` created \`/dev/ttyUSB0\`.
- Synology's own \`nutdrv_qx\` with \`protocol = megatec\` successfully reads UPS values over the serial TTY.

## Installed Runtime

- Kernel module copy: \`$MODULE_DST\`
- Stock UPS service wrapper: \`$STACK_SCRIPT\`
- Systemd unit: \`$STACK_UNIT\`
- Synology UPS service drop-in: \`$UPS_USB_DROPIN\`
- Synology safe-shutdown drop-in: \`$SAFE_SHUTDOWN_DROPIN\`
- Safe-shutdown wrapper: \`$SAFE_SHUTDOWN_SCRIPT\`
- UPS scheduler command wrapper: \`$UPSSCHED_CMD_SCRIPT\`
- UPS battery-mode watchdog: \`$WATCHDOG_SCRIPT\`
- UPS replug udev rule: \`$UDEV_RULE\`
- Healthcheck script: \`$HEALTH_SCRIPT\`
- Healthcheck timer: \`$HEALTH_TIMER\`
- Watchdog timer: \`$WATCHDOG_TIMER\`
- DSM NUT config: \`$UPS_CONF\`
- DSM NUT users: \`$UPSD_USERS\`
- DSM UPS scan table: \`$NUTSCAN_USB\`

## Runtime Design

- The NAS uses Synology's stock NUT daemons and callbacks: \`nutdrv_qx\`, \`upsd\`, \`upsmon\`, \`upssched\`, and \`/usr/syno/bin/synoups\`.
- \`ups-usb.service\` is active, but a drop-in points its startup to \`$STACK_SCRIPT\`.
- \`$STACK_SCRIPT\` loads \`ch341.ko\`, finds the CH341-backed \`/dev/ttyUSB*\`, writes the DSM NUT config for \`nutdrv_qx\`, and starts the stock NUT daemons directly.
- Synology's original \`ups-usb.sh start\` wrapper is intentionally bypassed for startup because it rewrites \`port\` to \`auto\`, which breaks this serial UPS.
- The udev rule restarts \`ups-usb.service\` if the UPS serial TTY is replugged.
- DSM wait time is set to \`$WAIT_SECONDS\` seconds.
- \`upssched\` uses \`$UPSSCHED_CMD_SCRIPT\` as its command script for battery-mode and mains-restored notifications.
- \`$WATCHDOG_TIMER\` runs every minute and owns the timed shutdown action. If the UPS remains on battery for \`$WAIT_SECONDS\` seconds, it sends the UPS shutdown-return command as root while DSM is still fully running, then calls Synology's low-battery Safe Mode path.
- \`ups_safeshutdown\` is set to \`$SHUTDOWN_UPS\`. This remains enabled for DSM consistency, but the primary output-cut command is now sent before DSM enters Safe/Standby Mode.
- \`safe-shutdown.service\` has a drop-in that runs \`$SAFE_SHUTDOWN_SCRIPT\` instead of Synology's original safe-shutdown script. The wrapper preserves Synology's final \`synoups shutdownups\` call, but uses the serial-aware UPS startup path first. This matters because Synology's original script calls \`ups-usb.sh start\` directly, and that script rewrites the serial UPS port to \`auto\`.
- The NUT driver is configured with \`offdelay = $UPS_OFF_DELAY_SECONDS\` and \`ondelay = $UPS_ON_DELAY_SECONDS\`. Because \`stayoff\` is not set, \`nutdrv_qx\` uses its normal return behavior: shut the load off, then turn it back on after mains power has returned. The exact behavior must be verified with a controlled outage test, because some low-cost UPS firmware ignores parts of the command.
- The UPS does not report battery charge/runtime/model fields directly. The config supplies NUT fallback values so DSM can display a normal USB UPS. Battery charge is an estimate, and displayed runtime is aligned with the configured DSM wait time; shutdown still uses the fixed timer.
- The healthcheck timer runs 5 minutes after boot and every 15 minutes after that. It checks live UPS monitoring plus the persistent boot hook, UPS service drop-in, scheduler wrapper, watchdog timer, safe-shutdown drop-in, DSM wait time, and DSM UPS-output-shutdown flag. If the setup is still broken after an automatic restart attempt, it sends a DSM notification to \`@administrators\` with email delivery requested. The first healthy timer run after boot sends a success notification by default; set \`HEALTH_NOTIFY_OK_ON_BOOT=no\` during install to suppress it.

## DSM Settings To Check

- Control Panel -> Hardware & Power -> UPS:
  - UPS support should be enabled.
  - UPS type should show USB UPS.
  - Time before entering Standby/Safe Mode should match the intended UPS wait time. The install default is 15 minutes.
  - "Shut down UPS when the system enters Standby Mode" should be checked if you want to avoid fully draining the UPS battery during long outages.
- Control Panel -> Hardware & Power -> General:
  - Enable automatic restart after a power failure if you want the NAS to start after the UPS battery fully drains and AC later returns.
- Control Panel -> Notification -> Email:
  - Confirm email delivery is configured and tested.
  - The healthcheck uses DSM notifications to \`@administrators\`; DSM's notification rules decide which administrators receive email.
- If you change UPS settings in Control Panel and DSM restarts its own wrapper, run \`systemctl restart ch341-ups.service\` afterward. The healthcheck will also try to recover this automatically.

## Useful Commands

\`\`\`sh
systemctl status ch341-ups.service --no-pager
systemctl status ups-usb.service --no-pager
systemctl cat safe-shutdown.service
$STACK_SCRIPT status
/usr/bin/upsc ups@localhost
grep -E '^CMDSCRIPT|^AT ONBATT|^AT ONLINE' /etc/ups/upssched.conf
systemctl list-timers ch341-ups-healthcheck.timer --no-pager
systemctl list-timers ch341-ups-watchdog.timer --no-pager
systemctl status ch341-ups-healthcheck.service --no-pager
systemctl status ch341-ups-watchdog.service --no-pager
\`\`\`

## Test Plan

1. Basic status test:
   Run \`$STACK_SCRIPT status\` and verify \`ups.status: OL\`, \`input.voltage\`, and \`battery.voltage\` are present.
   Also run \`/usr/syno/bin/synoups status\`. Expected: it ends with \`OL\`; after the fallback-value update it should not print unsupported-variable errors.

2. DSM service restart test:
   Run \`systemctl restart ch341-ups.service\`, then run \`/usr/bin/upsc ups@localhost ups.status\`. Expected: \`OL\` while mains power is present.

3. Healthcheck test:
   Run \`$HEALTH_SCRIPT\`. Expected: exit code \`0\` and no warning notification. Check the timers with \`systemctl list-timers ch341-ups-healthcheck.timer ch341-ups-watchdog.timer --no-pager\`.

4. Short power-loss test:
   With no critical writes running, unplug the UPS input from wall power but keep the NAS plugged into the UPS. Within one or two polling intervals, \`/usr/bin/upsc ups@localhost ups.status\` should show \`OB\`. Plug wall power back in before the configured DSM wait time expires; status should return to \`OL\`, and DSM should not enter Safe Mode.

5. Full Safe/Standby Mode test:
   Only run this when it is acceptable for DSM to stop services. Unplug the UPS input from wall power and wait longer than the configured DSM wait time. Expected: the watchdog sends UPS shutdown-return as root, then DSM enters Safe/Standby Mode. Around \`$UPS_OFF_DELAY_SECONDS\` seconds after the shutdown-return command, UPS output should cut. Restore wall power. The UPS should turn output back on, and the NAS should start because automatic restart after power failure is enabled in Hardware & Power -> General.

6. Shortened full-flow test:
   For a faster controlled test, temporarily set the DSM UPS wait time to 1 minute in Control Panel, unplug the UPS input, and wait for Safe/Standby Mode plus UPS output shutoff. With the default \`offdelay\`, output cut can take about 5 minutes after the 1-minute timer fires. Restore wall power and confirm the NAS starts. After the test, restore the normal wait time in DSM.

7. DSM update test:
   After any DSM update, run \`$STACK_SCRIPT status\` and \`$HEALTH_SCRIPT\`. If the kernel version changed and \`ch341.ko\` no longer matches, the healthcheck should notify administrators and the module must be rebuilt for the new kernel.

## Upgrade Notes

- No DSM boot kernel was replaced.
- No Synology system script was patched.
- The module is loaded from \`/usr/local\` with \`insmod\`.
- Minor DSM updates that keep the same \`uname -r\` should usually keep working.
- DSM updates that change the running kernel ABI can make \`ch341.ko\` fail to load. The healthcheck detects this by comparing module \`vermagic\` with \`uname -r\` and sends an alert instead of failing silently.
- If the UPS returns AC before it cuts output, DSM's stock UPS client can reboot from Safe/Standby Mode. If DSM has told the UPS to cut output, startup after output returns depends on Control Panel -> Hardware & Power -> General -> automatic restart after power failure.
EOF
	chown "$DOC_USER":users "$doc" >/dev/null 2>&1 || true
	chmod 644 "$doc" || true
	log "Wrote $doc"
}

install() {
	require_root
	install_module
	write_stack_script
	write_ups_usb_dropin
	write_udev_rule
	write_stack_unit
	write_upssched_cmd_script
	write_watchdog_script
	write_watchdog_units
	write_health_script
	write_health_units
	write_safe_shutdown_script
	write_safe_shutdown_dropin
	systemctl daemon-reload
	systemctl enable ch341-ups.service
	systemctl enable ch341-ups-healthcheck.timer
	systemctl enable ch341-ups-watchdog.timer
	systemctl restart ch341-ups.service
	systemctl restart ch341-ups-healthcheck.timer
	systemctl restart ch341-ups-watchdog.timer
	"$HEALTH_SCRIPT" || true
	write_doc
	verify_all
}

restore() {
	require_root
	systemctl stop ch341-ups-healthcheck.timer >/dev/null 2>&1 || true
	systemctl disable ch341-ups-healthcheck.timer >/dev/null 2>&1 || true
	systemctl stop ch341-ups-watchdog.timer >/dev/null 2>&1 || true
	systemctl disable ch341-ups-watchdog.timer >/dev/null 2>&1 || true
	systemctl stop ch341-ups.service >/dev/null 2>&1 || true
	systemctl disable ch341-ups.service >/dev/null 2>&1 || true
	/usr/syno/lib/systemd/scripts/ups-usb.sh stop >/dev/null 2>&1 || true
	restore_file "$SYNOUPS_CONF"
	restore_file "$UPS_CONF"
	restore_file "$UPSD_USERS"
	restore_file "$UPSMON_CONF"
	restore_file "$UPSSCHED_CONF"
	restore_file "$NUTSCAN_USB"
	rm -f "$STACK_UNIT" "$HEALTH_SERVICE" "$HEALTH_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$STACK_SCRIPT" "$HEALTH_SCRIPT" "$SAFE_SHUTDOWN_SCRIPT" "$UPSSCHED_CMD_SCRIPT" "$WATCHDOG_SCRIPT" "$UPS_USB_DROPIN" "$SAFE_SHUTDOWN_DROPIN" "$UDEV_RULE"
	rmdir "$UPS_USB_DROPIN_DIR" >/dev/null 2>&1 || true
	rmdir "$SAFE_SHUTDOWN_DROPIN_DIR" >/dev/null 2>&1 || true
	udevadm control --reload-rules >/dev/null 2>&1 || true
	systemctl daemon-reload
	log "Restore complete. The module file in $MODULE_DIR was left in place."
}

case "${1:-install}" in
	install)
		install
		;;
	status)
		require_root
		"$STACK_SCRIPT" status
		systemctl status ch341-ups.service --no-pager || true
		systemctl status ch341-ups-healthcheck.timer --no-pager || true
		;;
	restore)
		restore
		;;
	*)
		printf 'Usage: %s {install|status|restore}\n' "$0" >&2
		exit 2
		;;
esac
