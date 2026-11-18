#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/octep"
VFIO_CONFIG="$SCRIPT_DIR/modules-load.d/xgs-vfio.conf"
BRIDGE_STACK_CONFIG="$SCRIPT_DIR/modules-load.d/xgs-bridge-stack.conf"
OCTEP_SYSCTL_CONFIG="$SCRIPT_DIR/sysctl.d/90-xgs-octep-forwarding.conf"
BLACKLIST_CONFIG="$SCRIPT_DIR/modprobe.d/xgs-octep.conf"
HEALTH_SCRIPT="$SCRIPT_DIR/scripts/xgs/npu-health.sh"
HEALTH_DEFAULT="$SCRIPT_DIR/systemd/xgs-npu-health.default"
ACCEL_STATUS_SCRIPT="$SCRIPT_DIR/scripts/xgs/accel-status.sh"
NAT_HELPER_SCRIPT="$SCRIPT_DIR/scripts/nat/xgs-nat.sh"
RUN_SCRIPT="$SCRIPT_DIR/scripts/xgs/npu-run.sh"
PLATFORM_SCRIPT="$SCRIPT_DIR/scripts/octep/npu-platform.sh"
OCTEP_PORT_SETUP_SCRIPT="$SCRIPT_DIR/scripts/octep/rpc-port-setup.sh"
OCTEP_OFFLOAD_ENABLE_SCRIPT="$SCRIPT_DIR/scripts/octep/offload-enable.sh"
OCTEP_RING_TEST_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-ring-test.sh"
OCTEP_SDP_BRINGUP_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-bringup.sh"
OCTEP_SDP_RECOVERY_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-recover-npu.sh"
MGMT_LINK_SCRIPT="$SCRIPT_DIR/scripts/npuctl/mgmt-link.sh"
HEALTH_SERVICE="$SCRIPT_DIR/systemd/xgs-npu-health.service"
HEALTH_TIMER="$SCRIPT_DIR/systemd/xgs-npu-health.timer"
OCTEP_SDP_BRINGUP_SERVICE="$SCRIPT_DIR/systemd/xgs-octep-sdp-bringup.service"
OCTEP_SDP_STATUS_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-status-check.sh"
OCTEP_SDP_STATUS_SERVICE="$SCRIPT_DIR/systemd/xgs-octep-sdp-status.service"
OCTEP_SDP_STATUS_TIMER="$SCRIPT_DIR/systemd/xgs-octep-sdp-status.timer"
OCTEP_MAILBOX_COMPAT_SCRIPT="$SCRIPT_DIR/scripts/tests/octep-tx2-mailbox-compat-test.sh"
OCTEP_MAILBOX_COMPAT_SERVICE="$SCRIPT_DIR/systemd/xgs-octep-mailbox-compat.service"
UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
DKMS_NAME=xgs-octep
DKMS_VERSION=0.1.2
EXPECTED_ALIAS='pci:v0000177Dd0000A300sv*sd*bc*sc*i*'
REPLACE_MANAGED=0

DESTDIR=${DESTDIR:-}
XGS_ROOT="$DESTDIR/usr/local/xgs/linux"
NPU_SENSOR_SOURCE_DIR=${XGS_NPU_SENSOR_SOURCE_DIR:-}
KVER=${KVER:-$(uname -r)}
KDIR=${KDIR:-/lib/modules/$KVER/build}

fail() {
	echo "xgs-linux-install: $*" >&2
	exit 1
}

case ${1:-} in
	"") ;;
	--replace-managed) REPLACE_MANAGED=1 ;;
	*) fail "usage: $0 [--replace-managed]" ;;
esac

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

install_config() {
	source=$1
	target=$2

	if [ "$REPLACE_MANAGED" -eq 1 ]; then
		install -D -m 0644 "$source" "$target"
		return
	fi
	if [ -e "$target" ]; then
		if cmp -s "$source" "$target"; then
			return
		fi
		source_rules=$(grep -Ev '^[[:space:]]*(#|$)' "$source" || true)
		target_rules=$(grep -Ev '^[[:space:]]*(#|$)' "$target" || true)
		[ "$source_rules" = "$target_rules" ] ||
			fail "refusing to overwrite a different file: $target"
		echo "xgs-linux-install: preserving equivalent local config $target"
		return
	fi
	install -D -m 0644 "$source" "$target"
}

install_script() {
	source=$1
	target=$2

	install_file "$source" "$target" 0755
}

install_unit() {
	source=$1
	target=$2

	install_file "$source" "$target" 0644
}

install_data() {
	source=$1
	target=$2

	install_file "$source" "$target" 0644
}

install_file() {
	source=$1
	target=$2
	mode=$3

	if [ -e "$target" ] && ! cmp -s "$source" "$target" &&
	   [ "$REPLACE_MANAGED" -ne 1 ]; then
		fail "refusing to overwrite a different file: $target"
	fi
	install -D -m "$mode" "$source" "$target"
}

verify_module() {
	module=$1
	aliases=$(modinfo -F alias "$module") ||
		fail "cannot read PCI aliases from $module"
	printf '%s\n' "$aliases" | grep -Fqx "$EXPECTED_ALIAS" ||
		fail "module does not declare the expected PCI alias $EXPECTED_ALIAS"

	vermagic=$(modinfo -F vermagic "$module") ||
		fail "cannot read vermagic from $module"
	module_kernel=${vermagic%% *}
	[ "$module_kernel" = "$KVER" ] ||
		fail "module vermagic $module_kernel does not match target kernel $KVER"
}

for command in install cmp grep mktemp; do
	require_command "$command"
done

[ -f "$SOURCE_DIR/Makefile" ] || fail "missing external-module Makefile"
[ -f "$SOURCE_DIR/octep.c" ] || fail "missing OCTEP source"
[ -f "$SOURCE_DIR/dkms.conf" ] || fail "missing DKMS configuration"
[ -f "$VFIO_CONFIG" ] || fail "missing VFIO modules-load configuration"
[ -f "$BRIDGE_STACK_CONFIG" ] || fail "missing bridge protocol modules-load configuration"
[ -f "$BLACKLIST_CONFIG" ] || fail "missing OCTEP modprobe configuration"
[ -f "$HEALTH_SCRIPT" ] || fail "missing NPU health-check script"
[ -f "$HEALTH_DEFAULT" ] || fail "missing NPU health sensor configuration"
[ -f "$ACCEL_STATUS_SCRIPT" ] || fail "missing NPU/SDP status script"
[ -f "$NAT_HELPER_SCRIPT" ] || fail "missing NAT script"
[ -f "$RUN_SCRIPT" ] || fail "missing NPU console runner"
[ -f "$PLATFORM_SCRIPT" ] || fail "missing NPU platform script"
[ -f "$OCTEP_PORT_SETUP_SCRIPT" ] || fail "missing OCTEP port-setup script"
[ -f "$OCTEP_OFFLOAD_ENABLE_SCRIPT" ] || fail "missing OCTEP offload-enable script"
[ -f "$OCTEP_RING_TEST_SCRIPT" ] || fail "missing OCTEP ring-test script"
[ -f "$OCTEP_SDP_BRINGUP_SCRIPT" ] || fail "missing OCTEP SDP bring-up script"
[ -f "$MGMT_LINK_SCRIPT" ] || fail "missing NPU management-link script"
[ -f "$HEALTH_SERVICE" ] || fail "missing NPU health-check systemd unit"
[ -f "$HEALTH_TIMER" ] || fail "missing NPU health-check timer"
[ -f "$OCTEP_SDP_BRINGUP_SERVICE" ] ||
	fail "missing OCTEP SDP bring-up systemd unit"
[ -f "$OCTEP_SDP_STATUS_SCRIPT" ] ||
	fail "missing OCTEP SDP status-check script"
[ -f "$OCTEP_SDP_STATUS_SERVICE" ] ||
	fail "missing OCTEP SDP status-check systemd unit"
[ -f "$OCTEP_SDP_STATUS_TIMER" ] ||
	fail "missing OCTEP SDP status-check timer"
[ -f "$OCTEP_SDP_RECOVERY_SCRIPT" ] ||
	fail "missing OCTEP blocked-NPU recovery script"
[ -f "$OCTEP_MAILBOX_COMPAT_SCRIPT" ] ||
	fail "missing OCTEP mailbox compatibility test"
[ -f "$OCTEP_MAILBOX_COMPAT_SERVICE" ] ||
	fail "missing OCTEP mailbox compatibility systemd unit"
[ -f "$UNINSTALL_SCRIPT" ] || fail "missing Linux uninstall script"

if [ -n "$NPU_SENSOR_SOURCE_DIR" ]; then
	for sensor_file in \
		bin/xgs-1us-sensors \
		lib/libsbsp.so.1 \
		lib/libgpiod.so.2
	do
		[ -r "$NPU_SENSOR_SOURCE_DIR/$sensor_file" ] ||
			fail "missing or unreadable NPU sensor file: $NPU_SENSOR_SOURCE_DIR/$sensor_file"
	done
fi

if [ -z "$DESTDIR" ]; then
	[ "$(id -u)" -eq 0 ] || fail "run as root, or set DESTDIR for a staged install"
	[ -f "$KDIR/Makefile" ] ||
		fail "kernel build tree not found: $KDIR; install matching kernel headers/devel or set KDIR"
	[ -f "/lib/modules/$KVER/build/Makefile" ] ||
		fail "DKMS requires matching kernel headers/devel at /lib/modules/$KVER/build; the installer will not install or upgrade a kernel"

	PACKAGE_MANAGER=
	PACKAGE_MANAGER_KIND=
	if command -v dnf >/dev/null 2>&1; then
		PACKAGE_MANAGER=$(command -v dnf)
		PACKAGE_MANAGER_KIND=dnf
	elif command -v yum >/dev/null 2>&1; then
		PACKAGE_MANAGER=$(command -v yum)
		PACKAGE_MANAGER_KIND=yum
	elif command -v apt-get >/dev/null 2>&1; then
		PACKAGE_MANAGER=$(command -v apt-get)
		PACKAGE_MANAGER_KIND=apt
	fi

	set --
	if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
		command -v dkms >/dev/null 2>&1 || set -- "$@" dkms
		command -v smcrouted >/dev/null 2>&1 || set -- "$@" smcroute
		if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1 ||
		   ! command -v ld >/dev/null 2>&1; then
			set -- "$@" build-essential
		fi
		if ! command -v modinfo >/dev/null 2>&1 || ! command -v depmod >/dev/null 2>&1 ||
		   ! command -v modprobe >/dev/null 2>&1; then
			set -- "$@" kmod
		fi
	else
		command -v dkms >/dev/null 2>&1 || set -- "$@" dkms
		command -v smcrouted >/dev/null 2>&1 || set -- "$@" smcroute
		command -v make >/dev/null 2>&1 || set -- "$@" make
		command -v gcc >/dev/null 2>&1 || set -- "$@" gcc
		command -v ld >/dev/null 2>&1 || set -- "$@" binutils
		if ! command -v modinfo >/dev/null 2>&1 || ! command -v depmod >/dev/null 2>&1 ||
		   ! command -v modprobe >/dev/null 2>&1; then
			set -- "$@" kmod
		fi
	fi
	if [ "$#" -gt 0 ]; then
		[ -n "$PACKAGE_MANAGER" ] ||
			fail "dnf, yum, or apt-get is required to install missing kernel-module build tools: $*"
		echo "xgs-linux-install: installing required packages: $*"
		if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
			DEBIAN_FRONTEND=noninteractive "$PACKAGE_MANAGER" install -y \
				--no-install-recommends "$@" ||
				fail "could not install the required packages: $*"
		else
			"$PACKAGE_MANAGER" install -y "$@" ||
				fail "could not install the required packages: $*"
		fi
	fi

	command -v dkms >/dev/null 2>&1 ||
		fail "DKMS package installation did not provide the dkms command"
	require_command modprobe
fi

for command in make gcc ld modinfo depmod; do
	require_command "$command"
done
[ -f "$KDIR/Makefile" ] || fail "kernel build tree not found: $KDIR"

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xgs-octep.XXXXXX")
cleanup() {
	rm -rf "$BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

install -d -m 0755 "$BUILD_DIR"
cp "$SOURCE_DIR/Makefile" "$SOURCE_DIR/octep.c" "$BUILD_DIR/"
make -C "$KDIR" M="$BUILD_DIR" W=1 modules
MODULE="$BUILD_DIR/octep.ko"
[ -f "$MODULE" ] || fail "kernel build did not produce octep.ko"
verify_module "$MODULE"

install_config "$VFIO_CONFIG" "$DESTDIR/etc/modules-load.d/xgs-vfio.conf"
install_data "$BRIDGE_STACK_CONFIG" \
	"$DESTDIR/etc/modules-load.d/xgs-bridge-stack.conf"
install_config "$BLACKLIST_CONFIG" "$DESTDIR/etc/modprobe.d/xgs-octep.conf"
install_config "$OCTEP_SYSCTL_CONFIG" \
	"$DESTDIR/etc/sysctl.d/90-xgs-octep-forwarding.conf"
install_config "$VFIO_CONFIG" "$XGS_ROOT/modules-load.d/xgs-vfio.conf"
install_data "$BRIDGE_STACK_CONFIG" \
	"$XGS_ROOT/modules-load.d/xgs-bridge-stack.conf"
install_config "$BLACKLIST_CONFIG" "$XGS_ROOT/modprobe.d/xgs-octep.conf"
install_data "$OCTEP_SYSCTL_CONFIG" \
	"$XGS_ROOT/sysctl.d/90-xgs-octep-forwarding.conf"
install_script "$SCRIPT_DIR/install.sh" "$XGS_ROOT/install.sh"
install_script "$UNINSTALL_SCRIPT" "$XGS_ROOT/uninstall.sh"
install_data "$SOURCE_DIR/Makefile" "$XGS_ROOT/octep/Makefile"
install_data "$SOURCE_DIR/octep.c" "$XGS_ROOT/octep/octep.c"
install_data "$SOURCE_DIR/dkms.conf" "$XGS_ROOT/octep/dkms.conf"
install_script "$HEALTH_SCRIPT" "$XGS_ROOT/scripts/xgs/npu-health.sh"
install_script "$ACCEL_STATUS_SCRIPT" "$XGS_ROOT/scripts/xgs/accel-status.sh"
install_script "$NAT_HELPER_SCRIPT" "$XGS_ROOT/scripts/nat/xgs-nat.sh"
install_script "$SCRIPT_DIR/scripts/nat/nat-port4.sh" "$XGS_ROOT/scripts/nat/nat-port4.sh"
install_script "$SCRIPT_DIR/scripts/nat/nat-off.sh" "$XGS_ROOT/scripts/nat/nat-off.sh"
install_unit "$SCRIPT_DIR/systemd/xgs-nat.service" "$DESTDIR/usr/lib/systemd/system/xgs-nat.service"
install_script "$RUN_SCRIPT" "$XGS_ROOT/scripts/xgs/npu-run.sh"
install_script "$PLATFORM_SCRIPT" "$XGS_ROOT/scripts/octep/npu-platform.sh"
install_script "$OCTEP_PORT_SETUP_SCRIPT" "$XGS_ROOT/scripts/octep/rpc-port-setup.sh"
install_script "$OCTEP_OFFLOAD_ENABLE_SCRIPT" "$XGS_ROOT/scripts/octep/offload-enable.sh"
install_script "$OCTEP_RING_TEST_SCRIPT" "$XGS_ROOT/scripts/octep/sdp-ring-test.sh"
install_script "$OCTEP_SDP_BRINGUP_SCRIPT" "$XGS_ROOT/scripts/octep/sdp-bringup.sh"
install_script "$OCTEP_SDP_RECOVERY_SCRIPT" "$XGS_ROOT/scripts/octep/sdp-recover-npu.sh"
install_script "$MGMT_LINK_SCRIPT" "$XGS_ROOT/scripts/npuctl/mgmt-link.sh"
install_unit "$HEALTH_SERVICE" "$XGS_ROOT/systemd/xgs-npu-health.service"
install_unit "$HEALTH_TIMER" "$XGS_ROOT/systemd/xgs-npu-health.timer"
if [ -n "$NPU_SENSOR_SOURCE_DIR" ]; then
	install_file "$NPU_SENSOR_SOURCE_DIR/bin/xgs-1us-sensors" \
		"$XGS_ROOT/npu-sensor/bin/xgs-1us-sensors" 0644
	install_file "$NPU_SENSOR_SOURCE_DIR/lib/libsbsp.so.1" \
		"$XGS_ROOT/npu-sensor/lib/libsbsp.so.1" 0644
	install_file "$NPU_SENSOR_SOURCE_DIR/lib/libgpiod.so.2" \
		"$XGS_ROOT/npu-sensor/lib/libgpiod.so.2" 0644
	sensor_config="$DESTDIR/etc/default/xgs-npu-health"
	if [ -e "$sensor_config" ]; then
		echo "xgs-linux-install: preserving existing sensor config $sensor_config"
	else
		install -D -m 0644 "$HEALTH_DEFAULT" "$sensor_config"
	fi
fi
install_unit "$OCTEP_SDP_BRINGUP_SERVICE" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-bringup.service"
install_script "$OCTEP_SDP_STATUS_SCRIPT" \
	"$XGS_ROOT/scripts/octep/sdp-status-check.sh"
install_unit "$OCTEP_SDP_STATUS_SERVICE" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.service"
install_unit "$OCTEP_SDP_STATUS_TIMER" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.timer"
install_script "$OCTEP_MAILBOX_COMPAT_SCRIPT" \
	"$XGS_ROOT/scripts/tests/octep-tx2-mailbox-compat-test.sh"
install_unit "$OCTEP_MAILBOX_COMPAT_SERVICE" \
	"$XGS_ROOT/systemd/xgs-octep-mailbox-compat.service"
install_unit "$HEALTH_SERVICE" "$DESTDIR/usr/lib/systemd/system/xgs-npu-health.service"
install_unit "$HEALTH_TIMER" "$DESTDIR/usr/lib/systemd/system/xgs-npu-health.timer"
install_unit "$OCTEP_SDP_BRINGUP_SERVICE" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-bringup.service"
install_unit "$OCTEP_SDP_STATUS_SERVICE" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-status.service"
install_unit "$OCTEP_SDP_STATUS_TIMER" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-status.timer"
install_unit "$OCTEP_MAILBOX_COMPAT_SERVICE" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-mailbox-compat.service"

DKMS_SOURCE="$DESTDIR/usr/src/$DKMS_NAME-$DKMS_VERSION"
DKMS_SOURCE_CHANGED=0
for source_file in Makefile octep.c dkms.conf; do
	if [ ! -f "$DKMS_SOURCE/$source_file" ] ||
	   ! cmp -s "$SOURCE_DIR/$source_file" "$DKMS_SOURCE/$source_file"; then
		DKMS_SOURCE_CHANGED=1
	fi
done
install -d -m 0755 "$DKMS_SOURCE"
install -m 0644 "$SOURCE_DIR/Makefile" "$SOURCE_DIR/octep.c" \
	"$SOURCE_DIR/dkms.conf" "$DKMS_SOURCE/"

if [ -n "$DESTDIR" ]; then
	MODULE_TARGET="$DESTDIR/lib/modules/$KVER/updates/xgs-octep/octep.ko"
	if [ -e "$MODULE_TARGET" ] && ! cmp -s "$MODULE" "$MODULE_TARGET"; then
		fail "refusing to overwrite a different module: $MODULE_TARGET"
	fi
	install -D -m 0644 "$MODULE" "$MODULE_TARGET"
	depmod -b "$DESTDIR" "$KVER"
	echo "xgs-linux-install: staged OCTEP module and VFIO configuration for $KVER"
	echo "xgs-linux-install: DKMS registration occurs when install.sh runs on the target"
	exit 0
fi

	DKMS_STATUS=$(dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$KVER" 2>/dev/null || true)
	if ! printf '%s\n' "$DKMS_STATUS" | grep -Fq ': installed' ||
	   [ "$DKMS_SOURCE_CHANGED" -eq 1 ]; then
		if ! dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" 2>/dev/null |
			grep -Fq "$DKMS_NAME/$DKMS_VERSION"; then
			dkms add -m "$DKMS_NAME" -v "$DKMS_VERSION"
		fi
		echo "xgs-linux-install: building DKMS module; configured hooks may rebuild initramfs"
		dkms build --force -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$KVER"
		dkms install --force -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$KVER"
	else
		echo "xgs-linux-install: OCTEP is already installed for $KVER; skipping DKMS rebuild"
fi

INSTALLED_ALIASES=$(modinfo -k "$KVER" -F alias octep) ||
	fail "DKMS did not install octep for kernel $KVER"
printf '%s\n' "$INSTALLED_ALIASES" | grep -Fqx "$EXPECTED_ALIAS" ||
	fail "installed octep module is missing the expected PCI alias"
INSTALLED_VERMAGIC=$(modinfo -k "$KVER" -F vermagic octep) ||
	fail "cannot read installed octep vermagic"
[ "${INSTALLED_VERMAGIC%% *}" = "$KVER" ] ||
	fail "installed octep module does not match kernel $KVER"
# A hand-copied unsigned or stripped module fails to load with a bare EINVAL.
[ -n "$(modinfo -k "$KVER" -F signer octep)" ] ||
	fail "resolved octep module is unsigned; reinstall through DKMS (--replace-managed)"
if grep -q '^octep ' /proc/modules 2>/dev/null; then
	echo "xgs-linux-install: a running octep is the previous build; run 'sudo rmmod octep' and the status timer reloads the new one within about 30 seconds"
fi

for module in vfio vfio_iommu_type1 vfio-pci; do
	modprobe "$module"
done

require_command systemctl
systemctl daemon-reload
systemctl enable --quiet xgs-octep-sdp-bringup.service
if systemctl cat smcroute.service >/dev/null 2>&1; then
	systemctl enable --quiet smcroute.service
	# Start only; a restart toggles allmulticast on every port and can disturb live traffic. Boot and reload refresh it in rpc-port-setup.sh.
	systemctl start smcroute.service || echo "xgs-linux-install: smcroute.service failed to start" >&2
fi
systemctl enable --quiet xgs-octep-mailbox-compat.service
systemctl enable --quiet xgs-npu-health.service
systemctl enable --quiet xgs-npu-health.timer
systemctl enable --quiet xgs-nat.service
systemctl start --quiet xgs-npu-health.timer
systemctl enable --quiet xgs-octep-sdp-status.timer
systemctl start --quiet xgs-octep-sdp-status.timer

echo "xgs-linux-install: installed OCTEP for $KVER and enabled DKMS kernel-update builds"
echo "xgs-linux-install: loaded VFIO modules only; octep was not loaded or bound"
echo "xgs-linux-install: enabled boot-time OCTEP load, SDP ring bring-up, and front-port setup"
echo "xgs-linux-install: enabled a read-only mailbox compatibility probe at boot"
echo "xgs-linux-install: enabled 30-second status checks and retries until OCTEP bring-up succeeds"
echo "xgs-linux-install: enabled guarded automatic recovery for the known blocked SDP handshake state"
echo "xgs-linux-install: enabled read-only NPU health reports every 5 seconds"
if [ -n "$NPU_SENSOR_SOURCE_DIR" ]; then
	echo "xgs-linux-install: installed NPU temperature sensor files outside the source tree"
fi
echo "xgs-linux-install: scripts and controls installed under /usr/local/xgs/linux"
echo "xgs-linux-install: use sudo /usr/local/xgs/linux/scripts/octep/sdp-bringup.sh to manually arm rings"
echo "xgs-linux-install: use sudo /usr/local/xgs/linux/scripts/octep/sdp-ring-test.sh for a guarded ring reload test"
echo "xgs-linux-install: DKMS initramfs behavior follows system configuration; bootloader settings were not changed"

echo "xgs-linux-install: default NAT: all LAN ports routed via Port 2 (octep1) WAN; optional: $XGS_ROOT/scripts/nat/nat-port4.sh or nat-off.sh"
