#!/usr/bin/env bash
set -euo pipefail

# Environment:
#   DEPS_FILE    Dependency config file. Default: dependencies.env.
#   WORK_DIR     Build workspace containing downloads/. Default: .work/build.
#   OUT_DIR      Directory receiving ch341.ko. Default: .work/out.
#   KERNEL_LOCALVERSION
#               Kernel localversion appended to vermagic. Default: +.
#
# Dependency variables are defined in DEPS_FILE:
#   DSM_PLATFORM
#   KERNEL_SOURCE_ARCHIVE
#   TOOLCHAIN_ARCHIVE
#
# This script does not download dependencies. Run `make deps` first.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work_dir="${WORK_DIR:-$root_dir/.work/build}"
download_dir="$work_dir/downloads"
source_dir="$work_dir/source"
toolchain_dir="$work_dir/toolchain"
out_dir="${OUT_DIR:-$root_dir/.work/out}"

mkdir -p "$download_dir" "$source_dir" "$toolchain_dir" "$out_dir"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

deps_file="${DEPS_FILE:-$root_dir/dependencies.env}"
[ -f "$deps_file" ] || die "missing dependency config: $deps_file"

# shellcheck disable=SC1090
. "$deps_file"

: "${DSM_PLATFORM:?}"
: "${KERNEL_SOURCE_ARCHIVE:?}"
: "${TOOLCHAIN_ARCHIVE:?}"
kernel_localversion="${KERNEL_LOCALVERSION:-+}"

kernel_archive="$download_dir/$KERNEL_SOURCE_ARCHIVE"
toolchain_archive="$download_dir/$TOOLCHAIN_ARCHIVE"

[ -f "$kernel_archive" ] || die "missing kernel source archive: $kernel_archive; run make deps"
[ -f "$toolchain_archive" ] || die "missing toolchain archive: $toolchain_archive; run make deps"

if [ ! -d "$source_dir/linux-4.4.x" ]; then
  log "Extracting kernel source"
  tar -C "$source_dir" -xf "$kernel_archive"
fi
if [ -z "$(find "$toolchain_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  log "Extracting toolchain"
  tar -C "$toolchain_dir" -xf "$toolchain_archive"
fi

kernel_dir="$source_dir/linux-4.4.x"
config_file="$kernel_dir/synoconfigs/$DSM_PLATFORM"
[ -f "$config_file" ] || die "missing kernel config: $config_file"

cross_prefix="$(find "$(cd "$toolchain_dir" && pwd)" -type f -name 'x86_64*-gcc' -print -quit | sed 's/gcc$//')"
[ -n "$cross_prefix" ] || die "could not find x86_64 cross compiler in $toolchain_dir"

cp "$config_file" "$kernel_dir/.config"
sed -i 's/^# CONFIG_USB_SERIAL_CH341 is not set/CONFIG_USB_SERIAL_CH341=m/' "$kernel_dir/.config"
grep -q '^CONFIG_USB_SERIAL=m' "$kernel_dir/.config" || printf '\nCONFIG_USB_SERIAL=m\n' >> "$kernel_dir/.config"

make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" LOCALVERSION="$kernel_localversion" oldconfig </dev/null
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" LOCALVERSION="$kernel_localversion" modules_prepare
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" LOCALVERSION="$kernel_localversion" M=drivers/usb/serial CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_CH341=m modules

install -m 0644 "$kernel_dir/drivers/usb/serial/ch341.ko" "$out_dir/ch341.ko"
modinfo "$out_dir/ch341.ko" >&2 || true
log "Built module: $out_dir/ch341.ko"
