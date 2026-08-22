#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root_dir/config/synology-dependencies.env"

work_dir="${WORK_DIR:-$root_dir/.work/build}"
download_dir="$work_dir/downloads"
source_dir="$work_dir/source"
toolchain_dir="$work_dir/toolchain"
out_dir="${OUT_DIR:-$root_dir/.work/out}"

mkdir -p "$download_dir" "$source_dir" "$toolchain_dir" "$out_dir"

fetch() {
  local url="$1"
  local sha="$2"
  local dst="$3"
  if [ ! -f "$dst" ]; then
    curl -fL --retry 3 --output "$dst" "$url"
  fi
  printf '%s  %s\n' "$sha" "$dst" | sha256sum -c -
}

kernel_archive="$download_dir/linux-4.4.x.txz"
toolchain_archive="$download_dir/geminilake-gcc1220_glibc236_x86_64-GPL.txz"
fetch "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_SHA256" "$kernel_archive"
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256" "$toolchain_archive"

if [ ! -d "$source_dir/linux-4.4.x" ]; then
  tar -C "$source_dir" -xf "$kernel_archive"
fi
if [ -z "$(find "$toolchain_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  tar -C "$toolchain_dir" -xf "$toolchain_archive"
fi

kernel_dir="$source_dir/linux-4.4.x"
config_file="$kernel_dir/synoconfigs/$DSM_PLATFORM"
[ -f "$config_file" ] || { echo "missing kernel config: $config_file" >&2; exit 1; }

cross_prefix="$(find "$toolchain_dir" -type f -name 'x86_64*-gcc' -print -quit | sed 's/gcc$//')"
[ -n "$cross_prefix" ] || { echo "could not find x86_64 cross compiler in $toolchain_dir" >&2; exit 1; }

cp "$config_file" "$kernel_dir/.config"
sed -i 's/^# CONFIG_USB_SERIAL_CH341 is not set/CONFIG_USB_SERIAL_CH341=m/' "$kernel_dir/.config"
grep -q '^CONFIG_USB_SERIAL=m' "$kernel_dir/.config" || printf '\nCONFIG_USB_SERIAL=m\n' >> "$kernel_dir/.config"

make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" oldconfig </dev/null
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" modules_prepare
make -C "$kernel_dir" ARCH=x86_64 CROSS_COMPILE="$cross_prefix" M=drivers/usb/serial CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_CH341=m modules

install -m 0644 "$kernel_dir/drivers/usb/serial/ch341.ko" "$out_dir/ch341.ko"
modinfo "$out_dir/ch341.ko" || true
printf 'built module: %s\n' "$out_dir/ch341.ko"
