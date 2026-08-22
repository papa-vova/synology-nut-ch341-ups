SHELL := /bin/sh

NAS ?=
DSM_USER ?= admin
MODULE ?= .work/out/ch341.ko
WAIT_SECONDS ?= 900
UPS_OFF_DELAY_SECONDS ?= 300
UPS_ON_DELAY_SECONDS ?= 180

.DEFAULT_GOAL := help

.PHONY: help require-nas require-module build bootstrap install check probe

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-12s %s\n' 'build' 'build .work/out/ch341.ko'
	@printf '  %-12s %s\n' 'bootstrap' 'prepare DSM permissions'
	@printf '  %-12s %s\n' 'install' 'install or update the DSM UPS setup'
	@printf '  %-12s %s\n' 'check' 'run the UPS health report'
	@printf '  %-12s %s\n' 'probe' 'collect USB/NUT diagnostics'

require-nas:
	@test -n "$(NAS)" || { printf '%s\n' 'ERROR: set NAS=user@host' >&2; exit 2; }

require-module:
	@test -f "$(MODULE)" || { printf 'ERROR: missing module: %s\n' "$(MODULE)" >&2; exit 1; }

build:
	./scripts/build-ch341-module.sh

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
