SHELL := /bin/sh

# Public make variables:
#   NAS                     NAS SSH host or host alias. Required except for build/help.
#   DSM_USER                DSM user used for SSH and sudo.
#   SSH_TARGET              Full SSH target. Default: DSM_USER@NAS.
#   MODULE                  Built ch341.ko path used by install.
#   WAIT_SECONDS            Default DSM UPS wait time used if DSM has no valid setting.
#   UPS_OFF_DELAY_SECONDS   UPS delay before cutting output after shutdown-return.
#   UPS_ON_DELAY_SECONDS    UPS delay before restoring output after mains returns.
#   SCP                     File-copy command used for NAS transfers.
#   SUDO_SSH                SSH command used for NAS sudo commands.
#   DEPS_FILE               Dependency config file used by deps/build.
#   WORK_DIR                Build/download workspace.
NAS ?=
DSM_USER ?= admin
SSH_TARGET ?= $(DSM_USER)@$(NAS)
MODULE ?= .work/out/ch341.ko
WAIT_SECONDS ?= 900
UPS_OFF_DELAY_SECONDS ?= 60
UPS_ON_DELAY_SECONDS ?= 180
SCP ?= scp -O
SUDO_SSH ?= ssh
DEPS_FILE ?= dependencies.env
WORK_DIR ?= .work/build

.DEFAULT_GOAL := help

.PHONY: help require-nas require-module deps build install check probe

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-12s %s\n' 'deps' 'download configured Synology build dependencies'
	@printf '  %-12s %s\n' 'build' 'build CH341 kernel module'
	@printf '  %-12s %s\n' 'install' 'install or update the DSM UPS setup'
	@printf '  %-12s %s\n' 'check' 'run the UPS health report'
	@printf '  %-12s %s\n' 'probe' 'run NAS USB/NUT diagnostics over SSH'

require-nas:
	@test -n "$(NAS)" || { printf '%s\n' 'ERROR: set NAS=host' >&2; exit 2; }

require-module:
	@test -f "$(MODULE)" || { printf 'ERROR: missing module: %s\n' "$(MODULE)" >&2; exit 1; }

deps:
	DEPS_FILE="$(DEPS_FILE)" WORK_DIR="$(WORK_DIR)" ./scripts/fetch-build-deps.sh

build:
	DEPS_FILE="$(DEPS_FILE)" WORK_DIR="$(WORK_DIR)" ./scripts/build-ch341-module.sh

install: require-nas require-module
	$(SCP) scripts/synology-ch341-ups-install.sh "$(MODULE)" "$(SSH_TARGET):/tmp/"
	$(SUDO_SSH) "$(SSH_TARGET)" "sudo /bin/sh /tmp/synology-ch341-ups-install.sh WAIT_SECONDS=$(WAIT_SECONDS) UPS_OFF_DELAY_SECONDS=$(UPS_OFF_DELAY_SECONDS) UPS_ON_DELAY_SECONDS=$(UPS_ON_DELAY_SECONDS)"

check: require-nas
	./scripts/check-over-ssh.sh "$(SSH_TARGET)"

probe: require-nas
	$(SCP) scripts/probe-nas-ups.sh "$(SSH_TARGET):/tmp/"
	$(SUDO_SSH) "$(SSH_TARGET)" "sudo /bin/sh /tmp/probe-nas-ups.sh"
