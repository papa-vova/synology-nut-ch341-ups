#!/bin/sh
set -eu

# Public environment:
#   WAIT_SECONDS            Default DSM UPS wait time used if DSM has no valid setting.
#   SHUTDOWN_UPS            yes/no default used if DSM has no valid UPS output shutdown setting.
#   UPS_OFF_DELAY_SECONDS   NUT offdelay for UPSes that honor shutdown-return.
#   UPS_ON_DELAY_SECONDS    NUT ondelay for UPSes that honor shutdown-return.
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
#   OUTPUT_SHUTDOWN_SCRIPT, WATCHDOG_SCRIPT, STACK_UNIT, HEALTH_SERVICE, HEALTH_TIMER
#   OUTPUT_SHUTDOWN_SERVICE, WATCHDOG_SERVICE, WATCHDOG_TIMER, SAFE_SHUTDOWN_DROPIN_DIR
#   UPS_USB_DROPIN_DIR, UDEV_RULE, FORCE_RESTART_FILE
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
OUTPUT_SHUTDOWN_SCRIPT="${OUTPUT_SHUTDOWN_SCRIPT:-/usr/local/sbin/ch341-ups-output-shutdown.sh}"
WATCHDOG_SCRIPT="${WATCHDOG_SCRIPT:-/usr/local/sbin/ch341-ups-watchdog.sh}"
STACK_UNIT="${STACK_UNIT:-/etc/systemd/system/ch341-ups.service}"
HEALTH_SERVICE="${HEALTH_SERVICE:-/etc/systemd/system/ch341-ups-healthcheck.service}"
HEALTH_TIMER="${HEALTH_TIMER:-/etc/systemd/system/ch341-ups-healthcheck.timer}"
OUTPUT_SHUTDOWN_SERVICE="${OUTPUT_SHUTDOWN_SERVICE:-/etc/systemd/system/ch341-ups-output-shutdown.service}"
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

command="install"
for arg in "$@"; do
	case "$arg" in
		status|restore)
			command="$arg"
			;;
		WAIT_SECONDS=*)
			WAIT_SECONDS="${arg#*=}"
			;;
		UPS_OFF_DELAY_SECONDS=*)
			UPS_OFF_DELAY_SECONDS="${arg#*=}"
			;;
		UPS_ON_DELAY_SECONDS=*)
			UPS_ON_DELAY_SECONDS="${arg#*=}"
			;;
		DOC_USER=*)
			DOC_USER="${arg#*=}"
			;;
		*)
			printf 'ERROR: unsupported argument: %s\n' "$arg" >&2
			exit 2
			;;
	esac
done
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
CONNECTED_STATE_FILE="${CONNECTED_STATE_FILE:-/run/ch341-ups-connected.state}"
POWER_STATE_FILE="${POWER_STATE_FILE:-/run/ch341-ups-power.state}"
FORCE_RESTART_FILE="${FORCE_RESTART_FILE:-/run/ch341-ups-force-restart}"

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

valid_ups_status_value() {
	case "$1" in
		OL*|OB*|LB*)
			return 0
			;;
	esac
	return 1
}

power_state_from_status_value() {
	case "$1" in
		*LB*)
			printf '%s\n' lowbattery
			;;
		*OB*)
			printf '%s\n' battery
			;;
		OL*)
			printf '%s\n' line
			;;
		*)
			return 1
			;;
	esac
}

seed_connected_state_for_upgrade() {
	status="$(/usr/bin/timeout 8 /usr/bin/upsc "$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	if valid_ups_status_value "$status"; then
		touch "$CONNECTED_STATE_FILE" 2>/dev/null || true
		power_state="$(power_state_from_status_value "$status" || true)"
		if [ -n "$power_state" ]; then
			printf '%s\n' "$power_state" > "$POWER_STATE_FILE" 2>/dev/null || true
		fi
		log "Existing UPS monitoring is already connected; service restart will not emit a connected notification"
	fi
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
UPS_PLUGIN_NOTIFY_SERVICE="ups-plugin-notify.service"
CONNECTED_STATE_FILE="$CONNECTED_STATE_FILE"
POWER_STATE_FILE="$POWER_STATE_FILE"
FORCE_RESTART_FILE="$FORCE_RESTART_FILE"

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

ups_monitoring_readable() {
	status="\$(current_ups_status)"
	valid_ups_status_value "\$status"
}

emit_connected_event_after_start() {
	if [ -e "\$CONNECTED_STATE_FILE" ]; then
		log "UPS monitoring was already connected; not emitting connected notification"
		return 0
	fi
	systemctl --no-block restart "\$UPS_PLUGIN_NOTIFY_SERVICE" >/dev/null 2>&1 || true
}

mark_connected() {
	touch "\$CONNECTED_STATE_FILE" 2>/dev/null || true
}

clear_connected() {
	rm -f "\$CONNECTED_STATE_FILE" 2>/dev/null || true
}

current_ups_status() {
	/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true
}

valid_ups_status_value() {
	case "\$1" in
		OL*|OB*|LB*)
			return 0
			;;
	esac
	return 1
}

power_state_from_status_value() {
	case "\$1" in
		*LB*)
			printf '%s\n' lowbattery
			;;
		*OB*)
			printf '%s\n' battery
			;;
		OL*)
			printf '%s\n' line
			;;
		*)
			return 1
			;;
	esac
}

write_power_state() {
	printf '%s\n' "\$1" > "\$POWER_STATE_FILE" 2>/dev/null || true
}

running_driver_port() {
	/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" driver.parameter.port 2>/dev/null || true
}

preserve_running_stack_if_healthy() {
	tty_dev="\$1"
	if [ -e "\$FORCE_RESTART_FILE" ]; then
		log "Forced UPS monitor restart requested"
		return 1
	fi
	status="\$(current_ups_status)"
	if ! valid_ups_status_value "\$status"; then
		return 1
	fi
	driver_port="\$(running_driver_port)"
	if [ "\$driver_port" != "\$tty_dev" ]; then
		log "Running UPS monitor uses \${driver_port:-empty}; expected \$tty_dev, restarting NUT daemons"
		return 1
	fi
	power_state="\$(power_state_from_status_value "\$status" || true)"
	if [ -n "\$power_state" ]; then
		write_power_state "\$power_state"
	fi
	mark_connected
	log "UPS monitoring already healthy via \$tty_dev (\$status); preserving running NUT daemons"
	return 0
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
	sed -i "/^NOTIFYCMD /d; /^NOTIFYFLAG ONBATT /d; /^NOTIFYFLAG ONLINE /d; /^NOTIFYFLAG LOWBATT /d; /^NOTIFYFLAG FSD /d; /^NOTIFYFLAG COMMOK /d; /^NOTIFYFLAG COMMBAD /d; /^NOTIFYFLAG NOCOMM /d" "$UPSMON_CONF"
	printf 'NOTIFYCMD /usr/sbin/upssched\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG ONBATT EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG ONLINE EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG LOWBATT EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG FSD EXEC\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG COMMOK IGNORE\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG COMMBAD IGNORE\n' >> "$UPSMON_CONF"
	printf 'NOTIFYFLAG NOCOMM IGNORE\n' >> "$UPSMON_CONF"
	set_or_append_directive "$UPSSCHED_CONF" "CMDSCRIPT" "\$UPSSCHED_CMD_SCRIPT"
	sed -i "/^AT ONBATT/d; /^AT ONLINE/d; /^AT LOWBATT/d; /^AT FSD/d" "$UPSSCHED_CONF"
	printf 'AT ONBATT * EXECUTE onbatt\n' >> "$UPSSCHED_CONF"
	printf 'AT ONLINE * EXECUTE online\n' >> "$UPSSCHED_CONF"
	printf 'AT LOWBATT * EXECUTE lowbatt\n' >> "$UPSSCHED_CONF"
	printf 'AT FSD * EXECUTE fsd\n' >> "$UPSSCHED_CONF"
	chown root:root "$UPSD_USERS" "$UPSMON_CONF" "$UPSSCHED_CONF" || true
	chmod 640 "$UPSD_USERS" "$UPSMON_CONF" "$UPSSCHED_CONF" || true
}

configure_synology_runtime() {
	mkdir -p "\$(dirname "\$SYNOUPS_CONF")"
	[ -e "\$SYNOUPS_CONF" ] || : > "\$SYNOUPS_CONF"
	chown root:root "\$SYNOUPS_CONF" || true
	chmod 640 "\$SYNOUPS_CONF" || true
	backup_once "\$SYNOUPS_CONF"
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_enabled yes
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" upsslave_enabled no
	/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_mode usb
	current_wait="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_wait_time 2>/dev/null || true)"
	case "\$current_wait" in
		""|*[!0-9]*)
			/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_wait_time "\$WAIT_SECONDS"
			;;
	esac
	current_safe="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	case "\$current_safe" in
		yes|no)
			;;
		*)
			/usr/syno/bin/synosetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown "\$SHUTDOWN_UPS"
			;;
	esac
}

start_stack() {
	load_module
	tty_dev="\$(find_ch341_tty || true)"
	if [ -z "\$tty_dev" ]; then
		clear_connected
		die "CH341 USB serial device \$VID:\$PID did not appear as /dev/ttyUSB*"
	fi
	ensure_scan_entry
	write_ups_conf "\$tty_dev"
	configure_synology_runtime
	configure_stock_nut_files
	if preserve_running_stack_if_healthy "\$tty_dev"; then
		return 0
	fi
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
		if ups_monitoring_readable; then
			log "Synology UPS USB service is reading \$UPS_NAME@localhost via \$tty_dev"
			emit_connected_event_after_start
			mark_connected
			rm -f "\$FORCE_RESTART_FILE" 2>/dev/null || true
			return 0
		fi
		i=\$((i + 1))
		sleep 1
	done
	/usr/bin/upsc "\$UPS_NAME@localhost" 2>&1 || true
	ps aux | grep -E 'nutdrv_qx|upsd|upsmon|upssched' | grep -v grep || true
	clear_connected
	die "Synology UPS USB service started but \$UPS_NAME@localhost is not readable"
}

stop_stack() {
	if [ -e "\$FORCE_RESTART_FILE" ]; then
		log "Forced UPS monitor restart requested; stopping NUT daemons"
		/usr/syno/lib/systemd/scripts/ups-usb.sh stop >/dev/null 2>&1 || true
		return 0
	fi
	if ups_monitoring_readable; then
		log "UPS monitoring is healthy; preserving running NUT daemons during service stop"
		return 0
	fi
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
KillMode=none
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
ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyUSB*", ATTRS{idVendor}=="$VID", ATTRS{idProduct}=="$PID", RUN+="/bin/sh -c 'touch $FORCE_RESTART_FILE; /bin/systemctl restart ups-usb.service'"
ACTION=="remove", SUBSYSTEM=="tty", KERNEL=="ttyUSB*", RUN+="/bin/sh -c 'rm -f $CONNECTED_STATE_FILE; touch $FORCE_RESTART_FILE; /bin/systemctl --no-block restart ups-plugout-notify.service'"
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

UPS_NAME="$UPS_NAME"
SYNOUPS="/usr/syno/bin/synoups"
LOG_TAG="ch341-ups"
SAFEMODE_REQUESTED="/run/ch341-ups-safemode.requested"
POWER_STATE_FILE="$POWER_STATE_FILE"
OUTPUT_SHUTDOWN_SERVICE_NAME="$(basename "$OUTPUT_SHUTDOWN_SERVICE")"

log() {
	logger -p user.err -t "\$LOG_TAG" "\$*"
}

pass_to_synology() {
	"\$SYNOUPS" "\$1" || log "Synology UPS command failed: \$1"
}

start_output_shutdown_helper() {
	systemctl reset-failed "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || true
	systemctl start --no-block "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || log "Could not start \$OUTPUT_SHUTDOWN_SERVICE_NAME"
}

read_power_state() {
	cat "\$POWER_STATE_FILE" 2>/dev/null || true
}

write_power_state() {
	printf '%s\n' "\$1" > "\$POWER_STATE_FILE" 2>/dev/null || true
}

current_power_state() {
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	case "\$status" in
		*LB*)
			printf '%s\n' lowbattery
			;;
		*OB*)
			printf '%s\n' battery
			;;
		OL*)
			printf '%s\n' line
			;;
		*)
			return 1
			;;
	esac
}

is_battery_state() {
	[ "\$1" = "battery" ] || [ "\$1" = "lowbattery" ]
}

handle_onbatt() {
	current="\$(current_power_state || true)"
	if [ "\$current" = "line" ]; then
		write_power_state line
		log "Skipping battery-mode notification because current UPS power state is line"
		return 0
	fi
	previous="\$(read_power_state)"
	if is_battery_state "\$previous"; then
		log "UPS power state already \$previous; not emitting duplicate battery-mode notification"
		return 0
	fi
	write_power_state battery
	pass_to_synology onbatt
}

handle_online() {
	rm -f "\$SAFEMODE_REQUESTED"
	current="\$(current_power_state || true)"
	if [ -n "\$current" ] && [ "\$current" != "line" ]; then
		write_power_state "\$current"
		log "Skipping AC-return notification because current UPS power state is \$current"
		return 0
	fi
	previous="\$(read_power_state)"
	if [ -z "\$previous" ] || [ "\$previous" = "line" ]; then
		write_power_state line
		log "UPS power state already \${previous:-unknown}; not emitting duplicate AC-return notification"
		return 0
	fi
	write_power_state line
	pass_to_synology online
}

handle_lowbatt() {
	current="\$(current_power_state || true)"
	if [ "\$current" = "line" ]; then
		write_power_state line
		log "Skipping low-battery notification because current UPS power state is line"
		return 0
	fi
	start_output_shutdown_helper
	previous="\$(read_power_state)"
	if [ "\$previous" = "lowbattery" ]; then
		log "UPS power state already lowbattery; not emitting duplicate low-battery notification"
		return 0
	fi
	write_power_state lowbattery
	pass_to_synology lowbatt
}

is_on_battery() {
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	case "\$status" in
		*OB*|*LB*|*FSD*)
			return 0
			;;
	esac
	log "Skipping UPS shutdown request because current UPS status is: \${status:-empty}"
	return 1
}

case "\${1:-}" in
	onbatt)
		handle_onbatt
		;;
	online)
		handle_online
		;;
	nocomm)
		pass_to_synology "\$1"
		;;
	fsd)
		if is_on_battery; then
			start_output_shutdown_helper
		fi
		pass_to_synology "\$1"
		;;
	lowbatt)
		handle_lowbatt
		;;
	waittimeup)
		if is_on_battery; then
			touch "\$SAFEMODE_REQUESTED"
			log "UPS scheduler wait time reached; requesting DSM Safe/Standby and UPS output cut"
			start_output_shutdown_helper
			pass_to_synology waittimeup
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

write_output_shutdown_script() {
	mkdir -p "$(dirname "$OUTPUT_SHUTDOWN_SCRIPT")"
	cat > "$OUTPUT_SHUTDOWN_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

UPS_NAME="$UPS_NAME"
SYNOUPS_CONF="$SYNOUPS_CONF"
STACK_SCRIPT="$STACK_SCRIPT"
VID="$VID"
PID="$PID"
SAFE_DOWN_MARKER="/tmp/ups.safedown"
SAFE_TARGET_STATUS_TIMEOUT_SECONDS=3
SAFE_MODE_POLL_SECONDS=5
SAFE_MODE_DETECT_TIMEOUT_SECONDS=300
AC_RETURN_POLL_SECONDS=10
AC_RETURN_LOG_INTERVAL_SECONDS=60
RAW_SHUTDOWN_COMMANDS="S.2 S.3 S.2R0003 S.3R0003 S00 S00R0003"
LOG_TAG="ch341-ups"
RECOVERY_LOG="/var/log/ch341-ups-recovery.log"

log() {
	logger -p user.err -t "\$LOG_TAG" "\$*" 2>/dev/null || true
	ts="\$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || true)"
	printf '%s %s\n' "\${ts:-unknown}" "\$*" >> "\$RECOVERY_LOG" 2>/dev/null || true
}

ups_output_shutdown_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

current_ups_status() {
	/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true
}

safe_shutdown_target_status() {
	/usr/bin/timeout "\$SAFE_TARGET_STATUS_TIMEOUT_SECONDS" synosystemctl get-active-status safe-shutdown.target 2>/dev/null || true
}

safe_mode_started() {
	[ -e "\$SAFE_DOWN_MARKER" ] && return 0
	/usr/syno/bin/synobootseq --is-safe-shutdown >/dev/null 2>&1 && return 0
	status="\$(safe_shutdown_target_status)"
	[ "\$status" = "active" ]
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

send_megatec_command() {
	tty="\$1"
	cmd="\$2"
	/usr/bin/timeout 1 dd if="\$tty" of=/dev/null bs=1 count=256 2>/dev/null || true
	exec 3<>"\$tty"
	printf '%s\r' "\$cmd" >&3
	sleep 0.3
	reply="\$(/usr/bin/timeout 3 dd bs=1 count=256 <&3 2>/dev/null | tr '\r' '\n' | tr -d '\000')"
	exec 3>&-
	printf '%s\n' "\$reply"
}

shutdown_active_from_q1() {
	reply="\$1"
	bits="\$(printf '%s\n' "\$reply" | awk '{print \$8}' | tr -dc '01')"
	[ "\$(printf '%s' "\$bits" | cut -c7)" = "1" ]
}

ac_online_from_q1() {
	reply="\$1"
	input_voltage="\$(printf '%s\n' "\$reply" | awk '{gsub(/^[(]/, "", \$1); print \$1}')"
	bits="\$(printf '%s\n' "\$reply" | awk '{print \$8}' | tr -dc '01')"
	utility_failed="\$(printf '%s' "\$bits" | cut -c1)"
	[ "\$utility_failed" != "1" ] || return 1
	printf '%s\n' "\$input_voltage" | awk '{ exit !((\$1 + 0) >= 90) }'
}

request_raw_megatec_output_cut() {
	tty="\$(find_ch341_tty || true)"
	if [ -z "\$tty" ]; then
		log "Could not find CH341 serial TTY for raw Megatec shutdown command"
		return 1
	fi
	if ! stty -F "\$tty" 2400 cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo min 0 time 10 2>/dev/null; then
		log "Could not configure \$tty for raw Megatec shutdown command"
		return 1
	fi
	for cmd in \$RAW_SHUTDOWN_COMMANDS; do
		log "Requesting safe-state UPS output cut through raw Megatec command \$cmd on \$tty"
		reply="\$(send_megatec_command "\$tty" "\$cmd")"
		if [ "\$reply" = "\$cmd" ] || [ "\$reply" = "#-1" ]; then
			log "Raw Megatec command \$cmd was rejected: \${reply:-empty}"
			continue
		fi
		sleep 2
		status_reply="\$(send_megatec_command "\$tty" Q1)"
		if shutdown_active_from_q1 "\$status_reply"; then
			log "UPS accepted raw Megatec output-cut command \$cmd"
			return 0
		fi
		log "Raw Megatec command \$cmd was not confirmed by Q1 status: \${status_reply:-empty}"
	done
	return 1
}

wait_for_ac_return_and_reboot() {
	waited=0
	last_log=0

	log "UPS output cut is unavailable; waiting in DSM Safe/Standby for AC return"
	while :; do
		tty="\$(find_ch341_tty || true)"
		if [ -n "\$tty" ] && stty -F "\$tty" 2400 cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo min 0 time 10 2>/dev/null; then
			status_reply="\$(send_megatec_command "\$tty" Q1)"
			if ac_online_from_q1 "\$status_reply"; then
				log "AC returned while DSM is in Safe/Standby; rebooting NAS to restore services"
				sync >/dev/null 2>&1 || true
				sleep 2
				/usr/syno/sbin/synopoweroff -f -r >/dev/null 2>&1 || /sbin/reboot -f >/dev/null 2>&1 || /bin/systemctl --force reboot >/dev/null 2>&1
				exit 0
			fi
		fi

		if [ "\$last_log" -eq 0 ] || [ \$((waited - last_log)) -ge "\$AC_RETURN_LOG_INTERVAL_SECONDS" ]; then
			log "Still waiting in DSM Safe/Standby for AC return; last Q1 status: \${status_reply:-unreadable}"
			last_log="\$waited"
		fi
		sleep "\$AC_RETURN_POLL_SECONDS"
		waited=\$((waited + AC_RETURN_POLL_SECONDS))
	done
}

is_on_battery() {
	status="\$(current_ups_status)"
	case "\$status" in
		*OB*|*LB*|*FSD*)
			return 0
			;;
	esac
	log "Skipping UPS output shutdown because current UPS status is: \${status:-empty}"
	return 1
}

stop_ups_daemons() {
	log "Stopping NUT daemons before UPS output shutdown"
	killall upsmon >/dev/null 2>&1 || true
	killall upssched >/dev/null 2>&1 || true
	killall upsd >/dev/null 2>&1 || true
	/usr/bin/upsdrvctl stop >/dev/null 2>&1 || true

	for _ in 1 2 3; do
		sleep 3
		count="\$(ps aux | grep -E '(upsd|upsmon|a ups)' | grep -cv grep)"
		[ "\$count" -eq 0 ] && return 0
	done
	return 0
}

if ! is_on_battery; then
	exit 0
fi

if ! ups_output_shutdown_enabled; then
	log "DSM UPS output shutdown is disabled; output-shutdown helper exiting"
	exit 0
fi

waited=0
while ! safe_mode_started; do
	if [ "\$waited" -ge "\$SAFE_MODE_DETECT_TIMEOUT_SECONDS" ]; then
		log "DSM Safe/Standby was not detected within \${SAFE_MODE_DETECT_TIMEOUT_SECONDS}s; refusing to cut UPS output"
		exit 1
	fi
	sleep "\$SAFE_MODE_POLL_SECONDS"
	waited=\$((waited + SAFE_MODE_POLL_SECONDS))
done

log "DSM Safe/Standby detected; trying raw Megatec return commands to cut UPS output"
/usr/syno/bin/syno_scemd_connector --signal 70 >/dev/null 2>&1 || true
stop_ups_daemons

if request_raw_megatec_output_cut; then
	exit 0
fi

log "UPS output-cut command failed; falling back to AC-return Safe/Standby reboot path"
wait_for_ac_return_and_reboot
EOF
	chown root:root "$OUTPUT_SHUTDOWN_SCRIPT" || true
	chmod 755 "$OUTPUT_SHUTDOWN_SCRIPT"
}

write_watchdog_script() {
	mkdir -p "$(dirname "$WATCHDOG_SCRIPT")"
	cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin:/usr/syno/sbin

UPS_NAME="$UPS_NAME"
DEFAULT_WAIT_SECONDS="$WAIT_SECONDS"
SYNOUPS_CONF="$SYNOUPS_CONF"
SYNOUPS="/usr/syno/bin/synoups"
SYNOPOWEROFF="/usr/syno/sbin/synopoweroff"
OUTPUT_SHUTDOWN_SERVICE_NAME="$(basename "$OUTPUT_SHUTDOWN_SERVICE")"
STATE_DIR="/run/ch341-ups-watchdog"
ONBATT_STAMP="\$STATE_DIR/onbattery.since"
SAFEMODE_REQUESTED="/run/ch341-ups-safemode.requested"
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

is_on_battery() {
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	case "\$status" in
		*OB*|*LB*|*FSD*)
			return 0
			;;
	esac
	log "UPS watchdog: current UPS status is not battery mode: \${status:-empty}"
	return 1
}

start_output_shutdown_helper() {
	systemctl reset-failed "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || true
	systemctl start --no-block "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || log "UPS watchdog: could not start \$OUTPUT_SHUTDOWN_SERVICE_NAME"
}

mkdir -p "\$STATE_DIR"

status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
now="\$(date +%s)"

if ! ups_support_enabled; then
	log "DSM UPS support is disabled; watchdog inactive"
	rm -f "\$ONBATT_STAMP" "\$SAFEMODE_REQUESTED"
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
		if [ -f "\$ONBATT_STAMP" ] || [ -f "\$SAFEMODE_REQUESTED" ]; then
			log "UPS watchdog saw mains restored: \$status"
		fi
		rm -f "\$ONBATT_STAMP" "\$SAFEMODE_REQUESTED"
		exit 0
		;;
	*)
		if [ -f "\$SAFEMODE_REQUESTED" ]; then
			log "UPS watchdog could not read valid UPS status after shutdown request: \${status:-empty}"
			exit 0
		fi
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

if [ -e "\$SAFEMODE_REQUESTED" ]; then
	exit 0
fi

touch "\$SAFEMODE_REQUESTED"
log "UPS watchdog battery timer reached \${elapsed}s (configured wait \${wait_seconds}s); requesting DSM Safe/Standby and UPS output cut"
start_output_shutdown_helper

if "\$SYNOUPS" waittimeup; then
	sleep 20
	safe_state="\$(synosystemctl get-active-status safe-shutdown.target 2>/dev/null || true)"
	safe_service="\$(systemctl is-active safe-shutdown.service 2>/dev/null || true)"
	if [ "\$safe_state" != "active" ] && [ "\$safe_service" != "active" ] && is_on_battery; then
		log "UPS watchdog: Synology wait-time path did not start Safe/Standby; calling synopoweroff -s directly"
		"\$SYNOPOWEROFF" -s || log "UPS watchdog: direct synopoweroff safe-shutdown command failed"
	fi
else
	log "UPS watchdog: Synology wait-time-expired Safe/Standby command failed"
fi
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

write_output_shutdown_unit() {
	mkdir -p "$(dirname "$OUTPUT_SHUTDOWN_SERVICE")"
	cat > "$OUTPUT_SHUTDOWN_SERVICE" <<EOF
[Unit]
Description=CH341 UPS output shutdown helper
DefaultDependencies=no
IgnoreOnIsolate=yes
After=ups-usb.service ch341-ups.service

[Service]
Type=simple
ExecStart=$OUTPUT_SHUTDOWN_SCRIPT
KillMode=process
TimeoutStartSec=0
EOF
	chown root:root "$OUTPUT_SHUTDOWN_SERVICE" || true
	chmod 644 "$OUTPUT_SHUTDOWN_SERVICE"
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
UPS_PLUGIN_NOTIFY_SERVICE="ups-plugin-notify.service"
UPS_PLUGOUT_NOTIFY_SERVICE="ups-plugout-notify.service"
WAIT_SECONDS="$WAIT_SECONDS"
SHUTDOWN_UPS="$SHUTDOWN_UPS"
STACK_UNIT="$STACK_UNIT"
HEALTH_TIMER="$HEALTH_TIMER"
STACK_UNIT_NAME="$(basename "$STACK_UNIT")"
HEALTH_TIMER_NAME="$(basename "$HEALTH_TIMER")"
WATCHDOG_SCRIPT="$WATCHDOG_SCRIPT"
WATCHDOG_TIMER="$WATCHDOG_TIMER"
WATCHDOG_TIMER_NAME="$(basename "$WATCHDOG_TIMER")"
OUTPUT_SHUTDOWN_SCRIPT="$OUTPUT_SHUTDOWN_SCRIPT"
OUTPUT_SHUTDOWN_SERVICE="$OUTPUT_SHUTDOWN_SERVICE"
OUTPUT_SHUTDOWN_SERVICE_NAME="$(basename "$OUTPUT_SHUTDOWN_SERVICE")"
UPS_USB_DROPIN="$UPS_USB_DROPIN"
SAFE_SHUTDOWN_SCRIPT="$SAFE_SHUTDOWN_SCRIPT"
SAFE_SHUTDOWN_DROPIN="$SAFE_SHUTDOWN_DROPIN"
UPSSCHED_CMD_SCRIPT="$UPSSCHED_CMD_SCRIPT"
UPSSCHED_CONF="$UPSSCHED_CONF"
UPSMON_CONF="$UPSMON_CONF"
SYNOUPS_CONF="$SYNOUPS_CONF"
UDEV_RULE="$UDEV_RULE"
FAIL_STAMP="/run/ch341-ups-health.failed"
CONNECTED_STATE_FILE="$CONNECTED_STATE_FILE"
FORCE_RESTART_FILE="$FORCE_RESTART_FILE"

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

ups_support_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_enabled 2>/dev/null || true)"
	[ "\$value" = "yes" ]
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
	[ -x "\$OUTPUT_SHUTDOWN_SCRIPT" ] || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT is missing or not executable"
	[ -x "\$WATCHDOG_SCRIPT" ] || append_issue "\$WATCHDOG_SCRIPT is missing or not executable"
	[ -f "\$UPS_USB_DROPIN" ] || append_issue "\$UPS_USB_DROPIN is missing"
	[ -f "\$SAFE_SHUTDOWN_DROPIN" ] || append_issue "\$SAFE_SHUTDOWN_DROPIN is missing"
	[ -f "\$UDEV_RULE" ] || append_issue "\$UDEV_RULE is missing"
	systemctl is-enabled --quiet "\$STACK_UNIT_NAME" || append_issue "\$STACK_UNIT_NAME is not enabled"
	systemctl is-enabled --quiet "\$HEALTH_TIMER_NAME" || append_issue "\$HEALTH_TIMER_NAME is not enabled"
	systemctl is-enabled --quiet "\$WATCHDOG_TIMER_NAME" || append_issue "\$WATCHDOG_TIMER_NAME is not enabled"
	systemctl is-active --quiet "\$WATCHDOG_TIMER_NAME" || append_issue "\$WATCHDOG_TIMER_NAME is not active"
	systemctl cat "\$UPS_PLUGIN_NOTIFY_SERVICE" >/dev/null 2>&1 || append_issue "\$UPS_PLUGIN_NOTIFY_SERVICE is missing"
	systemctl cat "\$UPS_PLUGOUT_NOTIFY_SERVICE" >/dev/null 2>&1 || append_issue "\$UPS_PLUGOUT_NOTIFY_SERVICE is missing"
	grep -Fq "\$UPS_PLUGIN_NOTIFY_SERVICE" "\$STACK_SCRIPT" 2>/dev/null || append_issue "UPS connected event is not wired"
	grep -Fq "\$UPS_PLUGOUT_NOTIFY_SERVICE" "\$UDEV_RULE" 2>/dev/null || append_issue "UPS disconnected udev event is not wired"
	systemctl cat ups-usb.service 2>/dev/null | grep -Fq "ExecStart=\$STACK_SCRIPT start" || append_issue "ups-usb.service is not using \$STACK_SCRIPT"
	systemctl cat ups-usb.service 2>/dev/null | grep -Fq "KillMode=none" || append_issue "ups-usb.service is allowed to kill preserved NUT daemons"
	grep -Fq "DSM Safe/Standby and UPS output cut" "\$WATCHDOG_SCRIPT" 2>/dev/null || append_issue "\$WATCHDOG_SCRIPT is not using the Safe/Standby-first output-cut path"
	grep -Fq '"\$SYNOUPS" waittimeup' "\$WATCHDOG_SCRIPT" 2>/dev/null || append_issue "\$WATCHDOG_SCRIPT is not requesting Synology Safe/Standby on wait-time expiry"
	systemctl cat "\$OUTPUT_SHUTDOWN_SERVICE_NAME" 2>/dev/null | grep -Fq "ExecStart=\$OUTPUT_SHUTDOWN_SCRIPT" || append_issue "\$OUTPUT_SHUTDOWN_SERVICE_NAME is not using \$OUTPUT_SHUTDOWN_SCRIPT"
	systemctl cat "\$OUTPUT_SHUTDOWN_SERVICE_NAME" 2>/dev/null | grep -Fq "IgnoreOnIsolate=yes" || append_issue "\$OUTPUT_SHUTDOWN_SERVICE_NAME is not isolated from DSM shutdown service stops"
	grep -Fq "\$OUTPUT_SHUTDOWN_SERVICE_NAME" "\$WATCHDOG_SCRIPT" 2>/dev/null || append_issue "\$WATCHDOG_SCRIPT is not wired to start \$OUTPUT_SHUTDOWN_SERVICE_NAME"
	grep -Fq "\$OUTPUT_SHUTDOWN_SERVICE_NAME" "\$UPSSCHED_CMD_SCRIPT" 2>/dev/null || append_issue "\$UPSSCHED_CMD_SCRIPT is not wired to start \$OUTPUT_SHUTDOWN_SERVICE_NAME"
	grep -Fq "pass_to_synology waittimeup" "\$UPSSCHED_CMD_SCRIPT" 2>/dev/null || append_issue "\$UPSSCHED_CMD_SCRIPT is not requesting Synology Safe/Standby on wait-time expiry"
	grep -Fq "request_raw_megatec_output_cut()" "\$OUTPUT_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT is missing raw Megatec output-cut command"
	grep -Fq "DSM Safe/Standby detected" "\$OUTPUT_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT does not wait for DSM Safe/Standby before output cut"
	grep -Fq 'RAW_SHUTDOWN_COMMANDS="S.2 S.3 S.2R0003 S.3R0003 S00 S00R0003"' "\$OUTPUT_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT is not using short return-style Megatec output-cut commands"
	grep -Fq "AC-return Safe/Standby reboot path" "\$OUTPUT_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT does not fall back to AC-return Safe/Standby reboot"
	grep -Fq "AC returned while DSM is in Safe/Standby" "\$OUTPUT_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$OUTPUT_SHUTDOWN_SCRIPT does not reboot on AC return from Safe/Standby"
	systemctl cat safe-shutdown.service 2>/dev/null | grep -Fq "ExecStart=\$SAFE_SHUTDOWN_SCRIPT" || append_issue "safe-shutdown.service is not using \$SAFE_SHUTDOWN_SCRIPT"
	grep -Fq "Starting raw UPS output-cut helper from Safe/Standby" "\$SAFE_SHUTDOWN_SCRIPT" 2>/dev/null || append_issue "\$SAFE_SHUTDOWN_SCRIPT is not starting the raw output-cut helper"
	grep -Fq "NOTIFYCMD /usr/sbin/upssched" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon is not configured to invoke upssched"
	grep -Fq "NOTIFYFLAG ONBATT EXEC" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon ONBATT notification does not execute commands"
	grep -Fq "NOTIFYFLAG ONLINE EXEC" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon ONLINE notification does not execute commands"
	grep -Fq "NOTIFYFLAG LOWBATT EXEC" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon LOWBATT notification does not execute commands"
	grep -Fq "NOTIFYFLAG FSD EXEC" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon FSD notification does not execute commands"
	grep -Fq "NOTIFYFLAG COMMOK IGNORE" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon COMMOK notification is not ignored"
	grep -Fq "NOTIFYFLAG COMMBAD IGNORE" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon COMMBAD notification is not ignored"
	grep -Fq "NOTIFYFLAG NOCOMM IGNORE" "\$UPSMON_CONF" 2>/dev/null || append_issue "upsmon NOCOMM notification is not ignored"
	grep -Fq "CMDSCRIPT \$UPSSCHED_CMD_SCRIPT" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched is not using \$UPSSCHED_CMD_SCRIPT"
	grep -Fq "AT ONBATT * EXECUTE onbatt" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched ONBATT event is not wired"
	grep -Fq "AT ONLINE * EXECUTE online" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched ONLINE event is not wired"
	grep -Fq "AT LOWBATT * EXECUTE lowbatt" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched LOWBATT event is not wired"
	grep -Fq "AT FSD * EXECUTE fsd" "\$UPSSCHED_CONF" 2>/dev/null || append_issue "upssched FSD event is not wired"
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
	log "UPS monitoring healthy on \$(hostname)"
	rm -f "\$FAIL_STAMP"
	touch "\$CONNECTED_STATE_FILE" 2>/dev/null || true
	exit 0
fi

first_issues="\$issues"

current_status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
if ! valid_ups_status "\$current_status"; then
	rm -f "\$CONNECTED_STATE_FILE" 2>/dev/null || true
fi
touch "\$FORCE_RESTART_FILE" 2>/dev/null || true
systemctl restart ch341-ups.service >/dev/null 2>&1 || true
sleep 8

if check_once; then
	log "UPS monitoring recovered on \$(hostname)"
	rm -f "\$FAIL_STAMP"
	exit 0
fi

if ! ups_support_enabled; then
	log "DSM UPS support is disabled; watchdog inactive"
	exit 0
fi

systemctl --no-block restart "\$UPS_PLUGOUT_NOTIFY_SERVICE" >/dev/null 2>&1 || true
rm -f "\$CONNECTED_STATE_FILE" 2>/dev/null || true
log "UPS monitoring problem on \$(hostname). Current issue: \$issues. Before automatic restart: \$first_issues. If this began after a DSM update and a vermagic mismatch is reported, rebuild ch341.ko for the new DSM kernel. Check \\\`systemctl status ch341-ups.service\\\` and \\\`$STACK_SCRIPT status\\\`."
touch "\$FAIL_STAMP"

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
UPS_NAME="$UPS_NAME"
OUTPUT_SHUTDOWN_SERVICE_NAME="$(basename "$OUTPUT_SHUTDOWN_SERVICE")"

log() {
	logger -p user.err -t ch341-ups "\$*"
}

ups_output_shutdown_enabled() {
	value="\$(/usr/syno/bin/synogetkeyvalue "\$SYNOUPS_CONF" ups_safeshutdown 2>/dev/null || true)"
	[ "\$value" = "yes" ]
}

is_on_battery() {
	status="\$(/usr/bin/timeout 8 /usr/bin/upsc "\$UPS_NAME@localhost" ups.status 2>/dev/null || true)"
	case "\$status" in
		*OB*|*LB*)
			return 0
			;;
	esac
	log "Skipping UPS output shutdown during Safe Mode because current UPS status is: \${status:-empty}"
	return 1
}

start_output_shutdown_helper() {
	systemctl reset-failed "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || true
	systemctl start --no-block "\$OUTPUT_SHUTDOWN_SERVICE_NAME" >/dev/null 2>&1 || log "Could not start \$OUTPUT_SHUTDOWN_SERVICE_NAME during Safe/Standby"
}

log "Safe shutdown started; preparing serial UPS shutdown-return path"

/bin/umount / >/dev/null 2>&1 || true

UpsMode="\$(/bin/get_key_value "\$SYNOUPS_CONF" ups_mode 2>/dev/null || true)"
[ -n "\$UpsMode" ] || UpsMode="usb"

if [ "\$UpsMode" = "usb" ]; then
	"\$STACK_SCRIPT" start || log "Could not restart serial UPS stack during safe shutdown"
elif [ "\$UpsMode" = "snmp" ] || [ "\$UpsMode" = "slave" ]; then
	/usr/syno/lib/systemd/scripts/ups-net.sh start
fi

/usr/syno/bin/scemd &
sleep 2

if ! ups_output_shutdown_enabled; then
	log "DSM UPS output shutdown is disabled; skipping UPS output shutdown command"
	exit 0
fi

if ! is_on_battery; then
	exit 0
fi

log "Starting raw UPS output-cut helper from Safe/Standby"
start_output_shutdown_helper
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
	systemctl cat ch341-ups-output-shutdown.service | sed -n '1,90p' || true
	log
	systemctl cat safe-shutdown.service | sed -n '1,90p' || true
	log
	grep '^MONITOR ' "$UPSMON_CONF" || true
	grep -E '^NOTIFYCMD|^NOTIFYFLAG (ONBATT|ONLINE|LOWBATT|FSD)' "$UPSMON_CONF" || true
	grep -E '^CMDSCRIPT|^AT (ONBATT|ONLINE|LOWBATT|FSD)' "$UPSSCHED_CONF" || true
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
- UPS output-shutdown helper: \`$OUTPUT_SHUTDOWN_SCRIPT\`
- UPS output-shutdown service: \`$OUTPUT_SHUTDOWN_SERVICE\`
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
- If DSM has no valid UPS wait time, the startup path initializes it to \`$WAIT_SECONDS\` seconds; otherwise DSM UI changes are preserved.
- \`upssched\` uses \`$UPSSCHED_CMD_SCRIPT\` as its command script for battery-mode and mains-restored notifications.
- The watchdog is a DSM systemd timer, not a separate always-running process.
- It uses DSM's UPS/NUT status to detect prolonged battery mode and trigger the Safe/Standby recovery path.
- It reads DSM's UPS wait time from Control Panel settings at runtime. Wait-time expiry and low-battery/FSD events start the shutdown manager.
- If DSM has no valid \`ups_safeshutdown\` value, the startup path initializes it to \`$SHUTDOWN_UPS\`. The shutdown manager reads that setting at runtime, re-checks live UPS status, lets DSM enter Safe/Standby, and then tries the Megatec output-cut path if the UPS is still \`OB\` or \`LB\`. If the UPS refuses output cut, the helper waits in Safe/Standby, polls the UPS directly, and reboots DSM when AC input returns.
- A compatibility hook covers DSM safe-shutdown flows that bypass the watchdog, so they still use the same serial-UPS recovery path.
- The NUT driver is configured with \`offdelay = $UPS_OFF_DELAY_SECONDS\` and \`ondelay = $UPS_ON_DELAY_SECONDS\`, but recovery does not depend on those values alone. If the UPS refuses output-cut commands, the Safe/Standby helper waits for AC input to return and reboots DSM from that safe state.
- The UPS does not report battery charge/runtime/model fields directly. The config supplies NUT fallback values so DSM can display a normal USB UPS. Battery charge/runtime are estimates; shutdown uses DSM's configured fixed wait time, not the displayed runtime estimate.
- The healthcheck is a DSM systemd timer, not a separate always-running process.
- It runs after boot and periodically on its own installed timer, 15 minutes by default. It reads DSM UPS settings during each run, but DSM Control Panel does not configure the healthcheck cadence.
- User-visible UPS notifications use DSM's stock Power supply events: UPS connected/recovered, battery mode, low battery, AC-return, and disconnected/unavailable.

## DSM Settings To Check

- Control Panel -> Hardware & Power -> General:
  - Enable automatic restart after a power failure if you want the NAS to start after the UPS battery fully drains and AC later returns.
- Control Panel -> Notification -> Email:
  - Confirm email delivery is configured and tested.
  - In Control Panel -> Notification -> Rules, edit the email-enabled rule and tick the Power supply UPS events that you want to be notified about.
  - The installer does not change DSM Notification Rule membership. Configure those checkboxes in DSM UI; the installed scripts always emit the stock UPS events, and DSM rules decide which delivery channels receive them.
- Control Panel -> Hardware & Power -> UPS:
  - UPS support should be enabled.
  - UPS type should show USB UPS.
  - Time before entering Standby/Safe Mode is the shutdown wait time used at runtime. The installer fallback, \`$WAIT_SECONDS\` seconds for this install, is used only when DSM has no valid saved wait time.
  - "Shut down UPS when the system enters Standby Mode" should be checked if the shutdown manager should try to cut UPS output during the shutdown path.
- UPS wait time and UPS-output-shutdown changes made in Control Panel are preserved across UPS service restarts and are read at runtime.

## Useful Commands

\`\`\`sh
systemctl status ch341-ups.service --no-pager
systemctl status ups-usb.service --no-pager
systemctl status ch341-ups-output-shutdown.service --no-pager
systemctl cat safe-shutdown.service
$STACK_SCRIPT status
/usr/bin/upsc ups@localhost
tail -n 120 /var/log/ch341-ups-recovery.log
grep -E '^CMDSCRIPT|^AT (ONBATT|ONLINE|LOWBATT|FSD)' /etc/ups/upssched.conf
systemctl list-timers ch341-ups-healthcheck.timer --no-pager
systemctl list-timers ch341-ups-watchdog.timer --no-pager
systemctl status ch341-ups-healthcheck.service --no-pager
systemctl status ch341-ups-watchdog.service --no-pager
\`\`\`

## Normal Notifications

- UPS monitoring connect/recovery: UPS-connected event.
- Mains input loss: battery-mode event.
- Mains input restored: AC-return event.
- Low battery: low-battery event when the UPS/NUT reports low battery.
- DSM wait-time expiry starts the shutdown path; it is not treated as a low-battery notification.
- UPS disconnected/unavailable: UPS-disconnected event.
- DSM UPS settings changes are settings changes only; when monitoring is already healthy, they preserve the already-running UPS monitor instead of restarting it.
- Power-state events use the single DSM-facing path: \`upsmon EXEC -> upssched -> wrapper -> synoups -> DSM stock UPS event\`.
- \`SYSLOG\`/\`WALL\` are not enabled for those events on DSM, because they can create duplicate DSM notifications outside the \`synoups\` path.
- The last observed power state is kept in \`/run/ch341-ups-power.state\` across service restarts; it resets on NAS boot.

## Test Plan

1. Basic status test:
   Run \`$STACK_SCRIPT status\` and verify \`ups.status: OL\`, \`input.voltage\`, and \`battery.voltage\` are present.
   Also run \`/usr/syno/bin/synoups status\`. Expected: it ends with \`OL\`; after the fallback-value update it should not print unsupported-variable errors.

2. DSM service restart test:
   Run \`systemctl restart ch341-ups.service\`, then run \`/usr/bin/upsc ups@localhost ups.status\`. Expected: \`OL\` while mains power is present.

3. Healthcheck test:
   Run \`$HEALTH_SCRIPT\`. Expected: exit code \`0\` and no problem notification. Check the timers with \`systemctl list-timers ch341-ups-healthcheck.timer ch341-ups-watchdog.timer --no-pager\`.

4. Short power-loss test:
   With no critical writes running, unplug the UPS input from wall power but keep the NAS plugged into the UPS. Within one or two polling intervals, \`/usr/bin/upsc ups@localhost ups.status\` should show \`OB\`. Plug wall power back in before the configured DSM wait time expires; status should return to \`OL\`, and DSM should not enter Safe Mode.

5. Full shutdown test:
   Only run this when it is acceptable for DSM to stop services and enter Safe/Standby. Unplug the UPS input from wall power and wait longer than the configured DSM UPS wait time, or until the UPS reports low battery. Expected: DSM enters Safe/Standby, the shutdown manager tries UPS output cut, and recovery happens either by UPS output returning after mains comes back or by the Safe/Standby helper rebooting DSM when AC input returns.

6. Shortened full-flow test:
   For a faster controlled test, temporarily set the DSM UPS wait time to 1 or 2 minutes in Control Panel, unplug the UPS input, and wait for DSM Safe/Standby. Restore wall power only after Safe/Standby is visible. Expected: the NAS boots automatically either after UPS output returns or after the AC-return helper reboots DSM from Safe/Standby. After the test, restore the normal wait time in DSM.

7. DSM update test:
   After any DSM update, run \`$STACK_SCRIPT status\` and \`$HEALTH_SCRIPT\`. If the kernel version changed and \`ch341.ko\` no longer matches, the healthcheck should notify administrators and the module must be rebuilt for the new kernel.

## Upgrade Notes

- No DSM boot kernel was replaced.
- No Synology system script was patched.
- The module is loaded from \`/usr/local\` with \`insmod\`.
- Minor DSM updates that keep the same \`uname -r\` should usually keep working.
- DSM updates that change the running kernel ABI can make \`ch341.ko\` fail to load. The healthcheck detects this by comparing module \`vermagic\` with \`uname -r\` and sends an alert instead of failing silently.
- If AC returns before UPS output is cut, the Safe/Standby helper should detect AC return over the serial UPS protocol and reboot DSM. If UPS output was cut, startup after output returns depends on Control Panel -> Hardware & Power -> General -> automatic restart after power failure.

## Remove

From the local repository, run \`make restore\` to remove the installed services,
scripts, drop-ins, udev rule, module copy, runtime state, recovery log, sudoers
rule, and this note, and to restore backed-up DSM/NUT config files. Reboot DSM
before installing again.
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
	write_output_shutdown_script
	write_output_shutdown_unit
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
	seed_connected_state_for_upgrade
	touch "$FORCE_RESTART_FILE" 2>/dev/null || true
	systemctl restart ch341-ups.service
	systemctl restart ch341-ups-healthcheck.timer
	systemctl restart ch341-ups-watchdog.timer
	"$HEALTH_SCRIPT" || true
	write_doc
	verify_all
}

restore() {
	require_root
	systemctl stop ch341-ups-output-shutdown.service >/dev/null 2>&1 || true
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
	rm -f "$STACK_UNIT" "$HEALTH_SERVICE" "$HEALTH_TIMER" "$OUTPUT_SHUTDOWN_SERVICE" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$STACK_SCRIPT" "$HEALTH_SCRIPT" "$SAFE_SHUTDOWN_SCRIPT" "$UPSSCHED_CMD_SCRIPT" "$OUTPUT_SHUTDOWN_SCRIPT" "$WATCHDOG_SCRIPT" "$UPS_USB_DROPIN" "$SAFE_SHUTDOWN_DROPIN" "$UDEV_RULE"
	rm -f "$CONNECTED_STATE_FILE" "$POWER_STATE_FILE" "$FORCE_RESTART_FILE"
	rm -f /run/ch341-ups-safemode.requested
	rm -rf /run/ch341-ups-watchdog
	rm -f "$SYNOUPS_CONF$BACKUP_SUFFIX" "$UPS_CONF$BACKUP_SUFFIX" "$UPSD_USERS$BACKUP_SUFFIX" "$UPSMON_CONF$BACKUP_SUFFIX" "$UPSSCHED_CONF$BACKUP_SUFFIX" "$NUTSCAN_USB$BACKUP_SUFFIX"
	rm -f /var/log/ch341-ups-recovery.log /var/log/systemd/ch341-ups-output-shutdown.service.log /tmp/ch341.ko /tmp/probe-nas-ups.sh /tmp/synology-ch341-ups-install.sh
	if [ -n "$DOC_USER" ]; then
		home="$(doc_home || true)"
		[ -n "$home" ] && rm -f "$home/$DOC_FILE_NAME"
	fi
	for doc in /var/services/homes/*/"$DOC_FILE_NAME" /volume1/homes/*/"$DOC_FILE_NAME" /home/*/"$DOC_FILE_NAME"; do
		[ -e "$doc" ] && rm -f "$doc"
	done
	case "$MODULE_DIR" in
		/usr/local/lib/modules/ch341-ups)
			rm -rf "$MODULE_DIR"
			;;
		*)
			log "Skipping unexpected module directory during restore: $MODULE_DIR"
			;;
	esac
	rmmod ch341 >/dev/null 2>&1 || true
	rm -f /etc/sudoers.d/synology-nut-ch341-ups
	rmdir "$UPS_USB_DROPIN_DIR" >/dev/null 2>&1 || true
	rmdir "$SAFE_SHUTDOWN_DROPIN_DIR" >/dev/null 2>&1 || true
	udevadm control --reload-rules >/dev/null 2>&1 || true
	systemctl daemon-reload
	log "Restore complete. Reboot DSM before installing again."
}

case "$command" in
	install)
		install
		;;
	status)
		require_root
		"$STACK_SCRIPT" status
		systemctl status ch341-ups.service --no-pager || true
		systemctl status ch341-ups-healthcheck.timer --no-pager || true
		systemctl status ch341-ups-output-shutdown.service --no-pager || true
		;;
	restore)
		restore
		;;
	*)
		printf 'Usage: %s {install|status|restore}\n' "$0" >&2
		exit 2
		;;
esac
