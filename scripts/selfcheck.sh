#!/usr/bin/env bash
set -euo pipefail

# Local repository checks. No NAS access and no downloads.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

deps_file="${DEPS_FILE:-$root_dir/dependencies.env}"
[ -f "$deps_file" ] || die "missing dependency config: $deps_file"

(
  # shellcheck disable=SC1090
  . "$deps_file"
  : "${DSM_PLATFORM:?}"
  : "${KERNEL_SOURCE_URL:?}"
  : "${KERNEL_SOURCE_SHA256:?}"
  : "${KERNEL_SOURCE_ARCHIVE:?}"
  : "${TOOLCHAIN_URL:?}"
  : "${TOOLCHAIN_SHA256:?}"
  : "${TOOLCHAIN_ARCHIVE:?}"
)

bash -n \
  scripts/fetch-build-deps.sh \
  scripts/build-ch341-module.sh \
  scripts/check-over-ssh.sh \
  scripts/selfcheck.sh

sh -n \
  scripts/nas-bootstrap-permissions.sh \
  scripts/probe-nas-ups.sh \
  scripts/synology-ch341-ups-install.sh

make -n deps >/dev/null
make -n build >/dev/null
make -n bootstrap NAS=admin@nas >/dev/null
make -n install NAS=admin@nas >/dev/null
make -n check NAS=admin@nas >/dev/null
make -n probe NAS=admin@nas >/dev/null

printf '%s\n' 'selfcheck: PASS'
