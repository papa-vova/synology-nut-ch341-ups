#!/usr/bin/env bash
set -euo pipefail

# Environment:
#   DEPS_FILE    Dependency config file. Default: dependencies.env.
#   WORK_DIR     Build/download workspace. Default: .work/build.
#
# Dependency variables are defined in DEPS_FILE:
#   KERNEL_SOURCE_URL, KERNEL_SOURCE_SHA256, KERNEL_SOURCE_ARCHIVE
#   TOOLCHAIN_URL, TOOLCHAIN_SHA256, TOOLCHAIN_ARCHIVE
#   VERIFY_SHA256

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

: "${KERNEL_SOURCE_URL:?}"
: "${KERNEL_SOURCE_SHA256:?}"
: "${KERNEL_SOURCE_ARCHIVE:?}"
: "${TOOLCHAIN_URL:?}"
: "${TOOLCHAIN_SHA256:?}"
: "${TOOLCHAIN_ARCHIVE:?}"

VERIFY_SHA256="${VERIFY_SHA256:-yes}"

work_dir="${WORK_DIR:-$root_dir/.work/build}"
download_dir="$work_dir/downloads"

mkdir -p "$download_dir"

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

fetch "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_SHA256" "$download_dir/$KERNEL_SOURCE_ARCHIVE"
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256" "$download_dir/$TOOLCHAIN_ARCHIVE"

log "Dependencies ready in $download_dir"
