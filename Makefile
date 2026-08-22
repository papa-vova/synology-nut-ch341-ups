SHELL := /bin/sh

# Public make variables:
#   NAS                     SSH target, for example admin@nas. Required except for build/help.
#   DSM_USER                DSM user authorized by bootstrap. Usually the user part of NAS.
#   MODULE                  Built ch341.ko path used by bootstrap/install.
#   WAIT_SECONDS            Initial DSM UPS wait time written by install.
#   UPS_OFF_DELAY_SECONDS   UPS delay before cutting output after shutdown-return.
#   UPS_ON_DELAY_SECONDS    UPS delay before restoring output after mains returns.
#   DEPS_FILE               Dependency config file used by deps/build.
#   WORK_DIR                Build/download workspace.
NAS ?=
DSM_USER ?= admin
MODULE ?= .work/out/ch341.ko
WAIT_SECONDS ?= 900
UPS_OFF_DELAY_SECONDS ?= 300
UPS_ON_DELAY_SECONDS ?= 180
DEPS_FILE ?= dependencies.env
WORK_DIR ?= .work/build

.DEFAULT_GOAL := help

.PHONY: help require-nas require-module selfcheck deps build bootstrap install check probe

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-12s %s\n' 'selfcheck' 'run local repository checks'
	@printf '  %-12s %s\n' 'deps' 'download configured Synology build dependencies'
	@printf '  %-12s %s\n' 'build' 'build CH341 kernel module'
	@printf '  %-12s %s\n' 'bootstrap' 'prepare DSM permissions'
	@printf '  %-12s %s\n' 'install' 'install or update the DSM UPS setup'
	@printf '  %-12s %s\n' 'check' 'run the UPS health report'
	@printf '  %-12s %s\n' 'probe' 'run NAS USB/NUT diagnostics over SSH'

require-nas:
	@test -n "$(NAS)" || { printf '%s\n' 'ERROR: set NAS=user@host' >&2; exit 2; }

require-module:
	@test -f "$(MODULE)" || { printf 'ERROR: missing module: %s\n' "$(MODULE)" >&2; exit 1; }

selfcheck:
	DEPS_FILE="$(DEPS_FILE)" ./scripts/selfcheck.sh

deps:
	DEPS_FILE="$(DEPS_FILE)" WORK_DIR="$(WORK_DIR)" ./scripts/fetch-build-deps.sh

build:
	DEPS_FILE="$(DEPS_FILE)" WORK_DIR="$(WORK_DIR)" ./scripts/build-ch341-module.sh

bootstrap: require-nas require-module
	scp scripts/nas-bootstrap-permissions.sh scripts/synology-ch341-ups-install.sh "$(MODULE)" "$(NAS):/tmp/"
	ssh "$(NAS)" "sudo INSTALL_USER=$(DSM_USER) /bin/sh /tmp/nas-bootstrap-permissions.sh"

install: require-nas require-module
	scp scripts/synology-ch341-ups-install.sh "$(MODULE)" "$(NAS):/tmp/"
	ssh "$(NAS)" "sudo /usr/local/sbin/synology-nut-ch341-apply.sh WAIT_SECONDS=$(WAIT_SECONDS) UPS_OFF_DELAY_SECONDS=$(UPS_OFF_DELAY_SECONDS) UPS_ON_DELAY_SECONDS=$(UPS_ON_DELAY_SECONDS)"

check: require-nas
	./scripts/check-over-ssh.sh "$(NAS)"

probe: require-nas
	scp scripts/probe-nas-ups.sh "$(NAS):/tmp/"
	ssh "$(NAS)" "sudo /bin/sh /tmp/probe-nas-ups.sh"
