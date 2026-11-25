#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
XGS_ROOT=/usr/local/xgs/linux
DKMS_NAME=xgs-octep
DKMS_VERSION=0.1.2

fail() {
	echo "xgs-linux-uninstall: $*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

remove_if_unchanged() {
	source=$1
	target=$2

	if [ -e "$target" ] || [ -L "$target" ]; then
		if [ -f "$source" ] && cmp -s "$source" "$target"; then
			rm -f -- "$target" || fail "could not remove managed file: $target"
			echo "xgs-linux-uninstall: removed $target"
		else
			echo "xgs-linux-uninstall: preserving modified or unrecognized file: $target" >&2
		fi
	fi
}

stop_and_disable_unit() {
	unit=$1

	if systemctl is-active --quiet "$unit"; then
		systemctl stop "$unit" || fail "could not stop $unit"
	fi
	if systemctl is-enabled --quiet "$unit"; then
		systemctl disable "$unit" || fail "could not disable $unit"
	fi
}

remove_empty_dir() {
	dir=$1

	if [ -d "$dir" ] && ! rmdir "$dir" 2>/dev/null; then
		echo "xgs-linux-uninstall: leaving non-empty directory: $dir" >&2
	fi
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
for command in cmp dkms grep rm rmdir systemctl; do
	require_command "$command"
done
for file in \
	install.sh uninstall.sh \
	modules-load.d/xgs-vfio.conf modprobe.d/xgs-octep.conf \
	sysctl.d/90-xgs-octep-forwarding.conf kea/kea-dhcp4.conf \
	scripts/nat/xgs-nat.sh scripts/nat/xgs-hardening.sh scripts/nat/xgs-ufw-admin.sh scripts/nat/xgs-lan.sh scripts/nat/nat-port4.sh scripts/nat/nat-off.sh \
	scripts/xgs/xgs-auto-update.sh scripts/xgs/xgs-auto-update-ctl.sh cron/xgs-auto-update \
	systemd/xgs-nat.service systemd/xgs-hardening.service \
	octep/Makefile octep/octep.c octep/dkms.conf \
	scripts/xgs/npu-health.sh scripts/xgs/npu-run.sh \
	scripts/octep/npu-platform.sh scripts/octep/rpc-port-setup.sh \
	scripts/octep/sdp-ring-test.sh scripts/octep/sdp-bringup.sh \
	scripts/octep/offload-enable.sh scripts/octep/offload-check.sh \
	scripts/octep/sdp-status-check.sh scripts/npuctl/mgmt-link.sh \
	systemd/xgs-npu-health.service systemd/xgs-npu-health.timer \
	systemd/xgs-octep-sdp-bringup.service \
	systemd/xgs-octep-sdp-status.service \
	systemd/xgs-octep-sdp-status.timer; do
	[ -f "$SCRIPT_DIR/$file" ] ||
		fail "managed reference file is missing: $SCRIPT_DIR/$file"
done

echo "xgs-linux-uninstall: stopping and disabling OCTEP and NPU health units"
stop_and_disable_unit xgs-octep-sdp-status.timer
stop_and_disable_unit xgs-octep-sdp-status.service
stop_and_disable_unit xgs-npu-health.timer
stop_and_disable_unit xgs-npu-health.service
stop_and_disable_unit xgs-octep-sdp-bringup.service
stop_and_disable_unit xgs-hardening.service
stop_and_disable_unit xgs-nat.service

DKMS_STATUS=$(dkms status) || fail "could not query DKMS registrations"
if printf '%s\n' "$DKMS_STATUS" |
	grep -Eq "^${DKMS_NAME}/${DKMS_VERSION}([,: ]|$)"; then
	dkms remove -m "$DKMS_NAME" -v "$DKMS_VERSION" --all ||
		fail "could not remove the OCTEP DKMS module"
fi

remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-npu-health.service" \
	/usr/lib/systemd/system/xgs-npu-health.service
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-npu-health.timer" \
	/usr/lib/systemd/system/xgs-npu-health.timer
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-bringup.service" \
	/usr/lib/systemd/system/xgs-octep-sdp-bringup.service
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-status.service" \
	/usr/lib/systemd/system/xgs-octep-sdp-status.service
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-status.timer" \
	/usr/lib/systemd/system/xgs-octep-sdp-status.timer
remove_if_unchanged "$SCRIPT_DIR/modules-load.d/xgs-vfio.conf" \
	/etc/modules-load.d/xgs-vfio.conf
remove_if_unchanged "$SCRIPT_DIR/modprobe.d/xgs-octep.conf" \
	/etc/modprobe.d/xgs-octep.conf
remove_if_unchanged "$SCRIPT_DIR/sysctl.d/90-xgs-octep-forwarding.conf" \
	/etc/sysctl.d/90-xgs-octep-forwarding.conf
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-nat.service" \
	/usr/lib/systemd/system/xgs-nat.service
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-hardening.service" \
	/usr/lib/systemd/system/xgs-hardening.service
remove_if_unchanged "$SCRIPT_DIR/kea/kea-dhcp4.conf" \
	/etc/kea/kea-dhcp4.conf

remove_if_unchanged "$SCRIPT_DIR/octep/Makefile" \
	"/usr/src/$DKMS_NAME-$DKMS_VERSION/Makefile"
remove_if_unchanged "$SCRIPT_DIR/octep/octep.c" \
	"/usr/src/$DKMS_NAME-$DKMS_VERSION/octep.c"
remove_if_unchanged "$SCRIPT_DIR/octep/dkms.conf" \
	"/usr/src/$DKMS_NAME-$DKMS_VERSION/dkms.conf"
remove_empty_dir "/usr/src/$DKMS_NAME-$DKMS_VERSION"

remove_if_unchanged "$SCRIPT_DIR/install.sh" "$XGS_ROOT/install.sh"
remove_if_unchanged "$SCRIPT_DIR/uninstall.sh" "$XGS_ROOT/uninstall.sh"
remove_if_unchanged "$SCRIPT_DIR/modules-load.d/xgs-vfio.conf" \
	"$XGS_ROOT/modules-load.d/xgs-vfio.conf"
remove_if_unchanged "$SCRIPT_DIR/modprobe.d/xgs-octep.conf" \
	"$XGS_ROOT/modprobe.d/xgs-octep.conf"
remove_if_unchanged "$SCRIPT_DIR/octep/Makefile" "$XGS_ROOT/octep/Makefile"
remove_if_unchanged "$SCRIPT_DIR/octep/octep.c" "$XGS_ROOT/octep/octep.c"
remove_if_unchanged "$SCRIPT_DIR/octep/dkms.conf" "$XGS_ROOT/octep/dkms.conf"
remove_if_unchanged "$SCRIPT_DIR/scripts/xgs/npu-health.sh" \
	"$XGS_ROOT/scripts/xgs/npu-health.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/xgs/npu-run.sh" \
	"$XGS_ROOT/scripts/xgs/npu-run.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/npu-platform.sh" \
	"$XGS_ROOT/scripts/octep/npu-platform.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/rpc-port-setup.sh" \
	"$XGS_ROOT/scripts/octep/rpc-port-setup.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/sdp-ring-test.sh" \
	"$XGS_ROOT/scripts/octep/sdp-ring-test.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/offload-enable.sh" \
	"$XGS_ROOT/scripts/octep/offload-enable.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/offload-check.sh" \
	"$XGS_ROOT/scripts/octep/offload-check.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/sdp-bringup.sh" \
	"$XGS_ROOT/scripts/octep/sdp-bringup.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/octep/sdp-status-check.sh" \
	"$XGS_ROOT/scripts/octep/sdp-status-check.sh"
remove_if_unchanged "$SCRIPT_DIR/scripts/npuctl/mgmt-link.sh" \
	"$XGS_ROOT/scripts/npuctl/mgmt-link.sh"
remove_if_unchanged "$SCRIPT_DIR/cron/xgs-auto-update" /etc/cron.d/xgs-auto-update
for f in xgs-auto-update.sh xgs-auto-update-ctl.sh; do
	remove_if_unchanged "$SCRIPT_DIR/scripts/xgs/$f" "$XGS_ROOT/scripts/xgs/$f"
done
for f in xgs-nat.sh xgs-hardening.sh xgs-ufw-admin.sh xgs-lan.sh nat-port4.sh nat-off.sh; do
	remove_if_unchanged "$SCRIPT_DIR/scripts/nat/$f" "$XGS_ROOT/scripts/nat/$f"
done
remove_if_unchanged "$SCRIPT_DIR/sysctl.d/90-xgs-octep-forwarding.conf" \
	"$XGS_ROOT/sysctl.d/90-xgs-octep-forwarding.conf"
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-npu-health.service" \
	"$XGS_ROOT/systemd/xgs-npu-health.service"
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-npu-health.timer" \
	"$XGS_ROOT/systemd/xgs-npu-health.timer"
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-bringup.service" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-bringup.service"
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-status.service" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.service"
remove_if_unchanged "$SCRIPT_DIR/systemd/xgs-octep-sdp-status.timer" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.timer"

# Files and units written by newer installer versions that are no longer in
# the manifest; they are installer-owned names, so remove them outright.
for legacy in \
	/usr/lib/systemd/system/xgs-octep-mailbox-compat.service \
	/etc/modules-load.d/xgs-bridge-stack.conf \
	/etc/default/xgs-npu-health \
	/etc/dnsmasq.d/xgs-lan.conf; do
	if [ -e "$legacy" ]; then
		systemctl disable --now "$(basename "$legacy")" >/dev/null 2>&1 || true
		rm -f -- "$legacy" && echo "xgs-linux-uninstall: removed legacy $legacy"
	fi
done
if [ -d "$XGS_ROOT" ]; then
	for legacy_dir in tests npu-sensor modules-load.d sysctl.d; do
		[ -d "$XGS_ROOT/$legacy_dir" ] && rm -rf -- "$XGS_ROOT/$legacy_dir" &&
			echo "xgs-linux-uninstall: removed legacy $XGS_ROOT/$legacy_dir"
	done
	for legacy_file in scripts/xgs/accel-status.sh scripts/octep/sdp-recover-npu.sh \
		scripts/octep/offload-enable.sh scripts/octep/offload-check.sh \
		scripts/octep/offload-summary.sh scripts/octep/offload-agent.py \
		scripts/octep/flow-build.py scripts/octep/flow-rpc-test.py \
		scripts/nat/nat-options.sh; do
		[ -e "$XGS_ROOT/$legacy_file" ] && rm -f -- "$XGS_ROOT/$legacy_file" &&
			echo "xgs-linux-uninstall: removed legacy $XGS_ROOT/$legacy_file"
	done
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
	for i in 0 2 3 4 5 6 7 8 9; do
		ufw delete allow in on octep$i >/dev/null 2>&1 || true
		ufw route delete allow in on octep$i out on octep1 >/dev/null 2>&1 || true
	done
	ufw delete allow in on enp2s0 >/dev/null 2>&1 || true
	echo "xgs-linux-uninstall: removed the installer's ufw rules"
fi

systemctl daemon-reload || fail "systemd daemon-reload failed"

remove_empty_dir "$XGS_ROOT/octep"
remove_empty_dir "$XGS_ROOT/modules-load.d"
remove_empty_dir "$XGS_ROOT/modprobe.d"
remove_empty_dir "$XGS_ROOT/scripts/xgs"
remove_empty_dir "$XGS_ROOT/scripts/octep"
remove_empty_dir "$XGS_ROOT/scripts/npuctl"
remove_empty_dir "$XGS_ROOT/scripts/nat"
remove_empty_dir "$XGS_ROOT/sysctl.d"
remove_empty_dir "$XGS_ROOT/scripts"
remove_empty_dir "$XGS_ROOT/systemd"
remove_empty_dir "$XGS_ROOT"
if [ -d "$XGS_ROOT" ]; then
	echo "xgs-linux-uninstall: still present under $XGS_ROOT (modified or unrecognized):" >&2
	find "$XGS_ROOT" -type f >&2
fi

if [ -d /sys/module/octep ]; then
	echo "xgs-linux-uninstall: OCTEP remains loaded for this boot; reboot to complete removal"
fi
echo "xgs-linux-uninstall: removed managed OCTEP files; installed OS packages and local data were left untouched"
