#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DSM_PLATFORM="${DSM_PLATFORM:-geminilake}"
KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-https://global.synologydownload.com/download/ToolChain/Synology%20NAS%20GPL%20Source/7.3-86009/geminilake/linux-4.4.x.txz}"
KERNEL_SOURCE_SHA256="${KERNEL_SOURCE_SHA256:-052359f42ac8bd311fa99286ff97d576eab747a8242ea5765c3b1c78b002f2de}"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://global.synologydownload.com/download/ToolChain/toolchain/7.4-90075/Intel%20x86%20Linux%204.4.302%20%28GeminiLake%29/geminilake-gcc1220_glibc236_x86_64-GPL.txz}"
TOOLCHAIN_SHA256="${TOOLCHAIN_SHA256:-97c2ec36e0130a2f7cd510655a7bf8c34b204311fcbd48001cc1ac4f61dcf030}"
VERIFY_SHA256="${VERIFY_SHA256:-yes}"

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

fetch() {
  local url="$1"
  local sha="$2"
  local dst="$3"
  if [ ! -f "$dst" ]; then
    log "Downloading $(basename "$dst")"
    curl -fL --retry 3 --output "$dst" "$url"
  fi
  if [ "$VERIFY_SHA256" = "yes" ]; then
    log "Verifying $(basename "$dst")"
    printf '%s  %s\n' "$sha" "$dst" | sha256sum -c - >&2
  fi
}

kernel_archive="$download_dir/linux-4.4.x.txz"
toolchain_archive="$download_dir/geminilake-gcc1220_glibc236_x86_64-GPL.txz"
fetch "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_SHA256" "$kernel_archive"
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256" "$toolchain_archive"

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

cross_prefix="$(find "$toolchain_dir" -type f -name 'x86_64*-gcc' -print -quit | sed 's/gcc$//')"
[ -n "$cross_prefix" ] || die "could not find x86_64 cross compiler in $toolchain_dir"

cp "$config_file" "$kernel_dir/.config"
sed -i 's/^# CONFIG_USB_SERIAL_CH341 is not set/CONFIG_USB_SERIAL_CH341=m/' "$kernel_dir/.config"
grep -q '^CONFIG_USB_SERIAL=m' "$kernel_dir/.config" || printf '\nCONFIG_USB_SERIAL=m\n' >> "$kernel_dir/.config"

make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" oldconfig </dev/null
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" modules_prepare
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" M=drivers/usb/serial CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_CH341=m modules

install -m 0644 "$kernel_dir/drivers/usb/serial/ch341.ko" "$out_dir/ch341.ko"
modinfo "$out_dir/ch341.ko" >&2 || true
log "Built module: $out_dir/ch341.ko"
