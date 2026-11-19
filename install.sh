#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/octep"
VFIO_CONFIG="$SCRIPT_DIR/modules-load.d/xgs-vfio.conf"
SYSCTL_CONFIG="$SCRIPT_DIR/sysctl.d/90-xgs-octep-forwarding.conf"
NAT_SCRIPT="$SCRIPT_DIR/scripts/nat/xgs-nat.sh"
NAT_LAN_SCRIPT="$SCRIPT_DIR/scripts/nat/xgs-lan.sh"
NAT_PORT4_SCRIPT="$SCRIPT_DIR/scripts/nat/nat-port4.sh"
NAT_OFF_SCRIPT="$SCRIPT_DIR/scripts/nat/nat-off.sh"
NAT_SERVICE="$SCRIPT_DIR/systemd/xgs-nat.service"
KEA_CONFIG="$SCRIPT_DIR/kea/kea-dhcp4.conf"
BLACKLIST_CONFIG="$SCRIPT_DIR/modprobe.d/xgs-octep.conf"
HEALTH_SCRIPT="$SCRIPT_DIR/scripts/xgs/npu-health.sh"
RUN_SCRIPT="$SCRIPT_DIR/scripts/xgs/npu-run.sh"
PLATFORM_SCRIPT="$SCRIPT_DIR/scripts/octep/npu-platform.sh"
OCTEP_PORT_SETUP_SCRIPT="$SCRIPT_DIR/scripts/octep/rpc-port-setup.sh"
OCTEP_RING_TEST_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-ring-test.sh"
OCTEP_OFFLOAD_ENABLE_SCRIPT="$SCRIPT_DIR/scripts/octep/offload-enable.sh"
OCTEP_OFFLOAD_CHECK_SCRIPT="$SCRIPT_DIR/scripts/octep/offload-check.sh"
OCTEP_SDP_BRINGUP_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-bringup.sh"
MGMT_LINK_SCRIPT="$SCRIPT_DIR/scripts/npuctl/mgmt-link.sh"
HEALTH_SERVICE="$SCRIPT_DIR/systemd/xgs-npu-health.service"
HEALTH_TIMER="$SCRIPT_DIR/systemd/xgs-npu-health.timer"
OCTEP_SDP_BRINGUP_SERVICE="$SCRIPT_DIR/systemd/xgs-octep-sdp-bringup.service"
OCTEP_SDP_STATUS_SCRIPT="$SCRIPT_DIR/scripts/octep/sdp-status-check.sh"
OCTEP_SDP_STATUS_SERVICE="$SCRIPT_DIR/systemd/xgs-octep-sdp-status.service"
OCTEP_SDP_STATUS_TIMER="$SCRIPT_DIR/systemd/xgs-octep-sdp-status.timer"
UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
DKMS_NAME=xgs-octep
DKMS_VERSION=0.1.2
EXPECTED_ALIAS='pci:v0000177Dd0000A300sv*sd*bc*sc*i*'
REPLACE_MANAGED=0
STEP_NO=0
STEP_TOTAL=9

DESTDIR=${DESTDIR:-}
XGS_ROOT="$DESTDIR/usr/local/xgs/linux"
KVER=${KVER:-$(uname -r)}
KDIR=${KDIR:-/lib/modules/$KVER/build}

fail() {
	echo "xgs-linux-install: $*" >&2
	exit 1
}

say() {
	echo "xgs-linux-install: $*"
}

# Visible progress: every phase announces itself before it can block.
step() {
	STEP_NO=$((STEP_NO + 1))
	echo ""
	echo "xgs-linux-install: [$STEP_NO/$STEP_TOTAL] $* ($(date +%H:%M:%S))"
}

# Bound a service action so a stuck unit cannot hang the installer.
run_timeout() {
	secs=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		"$@"
	fi
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
[ -f "$BLACKLIST_CONFIG" ] || fail "missing OCTEP modprobe configuration"
[ -f "$HEALTH_SCRIPT" ] || fail "missing NPU health-check script"
[ -f "$RUN_SCRIPT" ] || fail "missing NPU console runner"
[ -f "$PLATFORM_SCRIPT" ] || fail "missing NPU platform script"
[ -f "$OCTEP_PORT_SETUP_SCRIPT" ] || fail "missing OCTEP port-setup script"
[ -f "$OCTEP_RING_TEST_SCRIPT" ] || fail "missing OCTEP ring-test script"
[ -f "$OCTEP_OFFLOAD_ENABLE_SCRIPT" ] || fail "missing OCTEP offload-enable script"
[ -f "$OCTEP_OFFLOAD_CHECK_SCRIPT" ] || fail "missing OCTEP offload-check script"
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
[ -f "$UNINSTALL_SCRIPT" ] || fail "missing Linux uninstall script"
for f in "$SYSCTL_CONFIG" "$NAT_SCRIPT" "$NAT_LAN_SCRIPT" "$NAT_PORT4_SCRIPT" "$NAT_OFF_SCRIPT" \
	"$NAT_SERVICE" "$KEA_CONFIG"; do
	[ -f "$f" ] || fail "missing file in the checkout: $f"
done

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

	step "checking requirements (kernel $KVER, headers, build tools, DKMS)"
	say "kernel headers: /lib/modules/$KVER/build ok"
	if command -v dkms >/dev/null 2>&1; then
		say "dkms: $(command -v dkms) ($(dkms --version 2>/dev/null | head -n 1))"
	else
		say "dkms: not installed, will be installed"
	fi

	set --
	if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
		command -v dkms >/dev/null 2>&1 || set -- "$@" dkms
		command -v iptables >/dev/null 2>&1 || set -- "$@" iptables
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
		command -v iptables >/dev/null 2>&1 || set -- "$@" iptables
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
		step "installing required packages: $*"
		if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
			DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$PACKAGE_MANAGER" install -y \
				--no-install-recommends \
				-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" ||
				fail "could not install the required packages: $*"
		else
			"$PACKAGE_MANAGER" install -y "$@" ||
				fail "could not install the required packages: $*"
		fi
	else
		step "required packages"
		say "all required packages are already installed"
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

step "compiling the OCTEP module against $KDIR (about 1 minute)"
install -d -m 0755 "$BUILD_DIR"
cp "$SOURCE_DIR/Makefile" "$SOURCE_DIR/octep.c" "$BUILD_DIR/"
make -C "$KDIR" M="$BUILD_DIR" W=1 modules
MODULE="$BUILD_DIR/octep.ko"
[ -f "$MODULE" ] || fail "kernel build did not produce octep.ko"
verify_module "$MODULE"
say "module built and verified"

step "installing configuration, scripts and systemd units"

install_config "$VFIO_CONFIG" "$DESTDIR/etc/modules-load.d/xgs-vfio.conf"
install_config "$SYSCTL_CONFIG" "$DESTDIR/etc/sysctl.d/90-xgs-octep-forwarding.conf"
install_config "$SYSCTL_CONFIG" "$XGS_ROOT/sysctl.d/90-xgs-octep-forwarding.conf"
install_config "$BLACKLIST_CONFIG" "$DESTDIR/etc/modprobe.d/xgs-octep.conf"
install_config "$VFIO_CONFIG" "$XGS_ROOT/modules-load.d/xgs-vfio.conf"
install_config "$BLACKLIST_CONFIG" "$XGS_ROOT/modprobe.d/xgs-octep.conf"
install_script "$SCRIPT_DIR/install.sh" "$XGS_ROOT/install.sh"
install_script "$UNINSTALL_SCRIPT" "$XGS_ROOT/uninstall.sh"
install_data "$SOURCE_DIR/Makefile" "$XGS_ROOT/octep/Makefile"
install_data "$SOURCE_DIR/octep.c" "$XGS_ROOT/octep/octep.c"
install_data "$SOURCE_DIR/dkms.conf" "$XGS_ROOT/octep/dkms.conf"
install_script "$HEALTH_SCRIPT" "$XGS_ROOT/scripts/xgs/npu-health.sh"
install_script "$RUN_SCRIPT" "$XGS_ROOT/scripts/xgs/npu-run.sh"
install_script "$PLATFORM_SCRIPT" "$XGS_ROOT/scripts/octep/npu-platform.sh"
install_script "$OCTEP_PORT_SETUP_SCRIPT" "$XGS_ROOT/scripts/octep/rpc-port-setup.sh"
install_script "$OCTEP_RING_TEST_SCRIPT" "$XGS_ROOT/scripts/octep/sdp-ring-test.sh"
install_script "$OCTEP_OFFLOAD_ENABLE_SCRIPT" "$XGS_ROOT/scripts/octep/offload-enable.sh"
install_script "$OCTEP_OFFLOAD_CHECK_SCRIPT" "$XGS_ROOT/scripts/octep/offload-check.sh"
install_script "$OCTEP_SDP_BRINGUP_SCRIPT" "$XGS_ROOT/scripts/octep/sdp-bringup.sh"
install_script "$MGMT_LINK_SCRIPT" "$XGS_ROOT/scripts/npuctl/mgmt-link.sh"
install_unit "$HEALTH_SERVICE" "$XGS_ROOT/systemd/xgs-npu-health.service"
install_unit "$HEALTH_TIMER" "$XGS_ROOT/systemd/xgs-npu-health.timer"
install_unit "$OCTEP_SDP_BRINGUP_SERVICE" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-bringup.service"
install_script "$OCTEP_SDP_STATUS_SCRIPT" \
	"$XGS_ROOT/scripts/octep/sdp-status-check.sh"
install_unit "$OCTEP_SDP_STATUS_SERVICE" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.service"
install_unit "$OCTEP_SDP_STATUS_TIMER" \
	"$XGS_ROOT/systemd/xgs-octep-sdp-status.timer"
install_script "$NAT_SCRIPT" "$XGS_ROOT/scripts/nat/xgs-nat.sh"
install_script "$NAT_LAN_SCRIPT" "$XGS_ROOT/scripts/nat/xgs-lan.sh"
install_script "$NAT_PORT4_SCRIPT" "$XGS_ROOT/scripts/nat/nat-port4.sh"
install_script "$NAT_OFF_SCRIPT" "$XGS_ROOT/scripts/nat/nat-off.sh"
install_script "$SCRIPT_DIR/scripts/nat/xgs-hardening.sh" "$XGS_ROOT/scripts/nat/xgs-hardening.sh"
install_script "$SCRIPT_DIR/scripts/xgs/xgs-auto-update.sh" "$XGS_ROOT/scripts/xgs/xgs-auto-update.sh"
install_script "$SCRIPT_DIR/scripts/xgs/xgs-auto-update-ctl.sh" "$XGS_ROOT/scripts/xgs/xgs-auto-update-ctl.sh"
install_data "$SCRIPT_DIR/cron/xgs-auto-update" "$DESTDIR/etc/cron.d/xgs-auto-update"
install_unit "$NAT_SERVICE" "$DESTDIR/usr/lib/systemd/system/xgs-nat.service"
install_unit "$SCRIPT_DIR/systemd/xgs-hardening.service" "$DESTDIR/usr/lib/systemd/system/xgs-hardening.service"
install_unit "$HEALTH_SERVICE" "$DESTDIR/usr/lib/systemd/system/xgs-npu-health.service"
install_unit "$HEALTH_TIMER" "$DESTDIR/usr/lib/systemd/system/xgs-npu-health.timer"
install_unit "$OCTEP_SDP_BRINGUP_SERVICE" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-bringup.service"
install_unit "$OCTEP_SDP_STATUS_SERVICE" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-status.service"
install_unit "$OCTEP_SDP_STATUS_TIMER" \
	"$DESTDIR/usr/lib/systemd/system/xgs-octep-sdp-status.timer"

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

	step "registering and building the DKMS module (slow: may rebuild initramfs; please wait)"
	DKMS_STATUS=$(dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$KVER" 2>/dev/null || true)
	if ! printf '%s\n' "$DKMS_STATUS" | grep -Fq ': installed' ||
	   [ "$DKMS_SOURCE_CHANGED" -eq 1 ]; then
		if ! dkms status -m "$DKMS_NAME" -v "$DKMS_VERSION" 2>/dev/null |
			grep -Fq "$DKMS_NAME/$DKMS_VERSION"; then
			dkms add -m "$DKMS_NAME" -v "$DKMS_VERSION"
		fi
		say "dkms build running"
		dkms build --force -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$KVER"
		say "dkms install running (initramfs update can take a minute)"
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

step "loading VFIO modules"
for module in vfio vfio_iommu_type1 vfio-pci; do
	modprobe "$module"
done

require_command systemctl
step "enabling OCTEP systemd units"
systemctl daemon-reload
systemctl enable --quiet xgs-octep-sdp-bringup.service
systemctl enable --quiet xgs-npu-health.service
systemctl enable --quiet xgs-npu-health.timer
systemctl start --quiet xgs-npu-health.timer
systemctl enable --quiet xgs-octep-sdp-status.timer
systemctl start --quiet xgs-octep-sdp-status.timer

step "installing DHCP (Kea) for the LAN ports"
if ! systemctl cat kea-dhcp4.service >/dev/null 2>&1 &&
   ! systemctl cat kea-dhcp4-server.service >/dev/null 2>&1; then
	if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
		kea_pkg=kea-dhcp4-server
	else
		kea_pkg=kea
	fi
	say "installing $kea_pkg"
	if [ "$PACKAGE_MANAGER_KIND" = apt ]; then
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$PACKAGE_MANAGER" install -y \
			--no-install-recommends \
			-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
			"$kea_pkg" || say "WARNING: could not install $kea_pkg; LAN ports will not serve DHCP"
	else
		"$PACKAGE_MANAGER" install -y "$kea_pkg" ||
			say "WARNING: could not install $kea_pkg; LAN ports will not serve DHCP"
	fi
fi
kea_unit=
for u in kea-dhcp4.service kea-dhcp4-server.service; do
	if systemctl cat "$u" >/dev/null 2>&1; then kea_unit=$u; break; fi
done
if [ -e /etc/dnsmasq.d/xgs-lan.conf ]; then
	rm -f /etc/dnsmasq.d/xgs-lan.conf
	systemctl try-restart dnsmasq.service >/dev/null 2>&1 || true
fi
if [ -n "$kea_unit" ]; then
	# The distro package ships its own kea-dhcp4.conf; keep it once as .dist
	if [ -e /etc/kea/kea-dhcp4.conf ] && ! cmp -s "$KEA_CONFIG" /etc/kea/kea-dhcp4.conf &&
	   [ ! -e /etc/kea/kea-dhcp4.conf.dist ]; then
		cp -p /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.dist
		say "kept the distro Kea config as /etc/kea/kea-dhcp4.conf.dist"
	fi
	install -D -m 0644 "$KEA_CONFIG" /etc/kea/kea-dhcp4.conf
	# Operator-owned static leases; never overwritten once it exists
	[ -e /etc/kea/xgs-reservations.json ] ||
		printf '[]\n' | install -D -m 0644 /dev/stdin /etc/kea/xgs-reservations.json
	systemctl enable --quiet "$kea_unit"
	say "starting $kea_unit (up to 60 s)"
	run_timeout 60 systemctl restart "$kea_unit" ||
		say "WARNING: $kea_unit did not start now (LAN ports appear after bring-up); check: journalctl -u $kea_unit"
else
	say "WARNING: no Kea service found; LAN ports will not serve DHCP"
fi

step "NAT and firewall (ufw)"
systemctl enable --quiet xgs-nat.service
# Optional conntrack tuning and packet sanity filtering: installed always, enabled only on request.
if [ "${XGS_HARDENING:-0}" = 1 ]; then
	systemctl enable --quiet xgs-hardening.service
	say "xgs-hardening.service enabled (conntrack tuning, mangle sanity filter)"
fi
# Unattended updates at 05:00 and 13:00 (/etc/cron.d/xgs-auto-update) need a cron daemon
# (Fedora: cronie/crond; Debian/Mint: cron). Kernel packages are held back.
cron_unit=
find_cron_unit() {
	cron_unit=
	for u in crond.service cron.service; do
		if systemctl cat "$u" >/dev/null 2>&1; then cron_unit=$u; break; fi
	done
}
step "Unattended updates (cron)"
find_cron_unit
if [ -z "$cron_unit" ]; then
	if command -v dnf >/dev/null 2>&1; then
		say "no cron daemon found; installing cronie (dnf)"
		dnf -y install cronie >/dev/null 2>&1 || true
	elif command -v apt-get >/dev/null 2>&1; then
		say "no cron daemon found; installing cron (apt)"
		DEBIAN_FRONTEND=noninteractive apt-get -y install cron >/dev/null 2>&1 || true
	elif command -v pacman >/dev/null 2>&1; then
		say "no cron daemon found; installing cronie (pacman)"
		pacman -S --needed --noconfirm cronie >/dev/null 2>&1 || true
	else
		echo "xgs-linux-install: no dnf, apt-get or pacman; skipping cron install (continuing)" >&2
	fi
	find_cron_unit
else
	say "cron daemon present: $cron_unit"
fi
if [ -n "$cron_unit" ]; then
	systemctl enable --quiet --now "$cron_unit" || echo "xgs-linux-install: could not start $cron_unit" >&2
	say "unattended updates scheduled 05:00 and 13:00 (disable: $XGS_ROOT/scripts/xgs/xgs-auto-update-ctl.sh disable)"
else
	echo "xgs-linux-install: no cron daemon (cronie/cron); unattended updates will not run until one is installed" >&2
fi
# CPU microcode comes from the distro (best effort; Debian needs non-free-firmware for these).
# XGS_SKIP_MICROCODE=1 skips it.
if [ "${XGS_SKIP_MICROCODE:-0}" != 1 ]; then
	ucode_pkg=
	case $(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null) in
	*AuthenticAMD*) ucode_pkg_dnf=amd-ucode-firmware; ucode_pkg_apt=amd64-microcode; ucode_pkg_pacman=amd-ucode ;;
	*GenuineIntel*) ucode_pkg_dnf=microcode_ctl; ucode_pkg_apt=intel-microcode; ucode_pkg_pacman=intel-ucode ;;
	*) ucode_pkg_dnf=; ucode_pkg_apt=; ucode_pkg_pacman= ;;
	esac
	if command -v dnf >/dev/null 2>&1; then
		ucode_pkg=$ucode_pkg_dnf
		[ -z "$ucode_pkg" ] || rpm -q "$ucode_pkg" >/dev/null 2>&1 || dnf -y install "$ucode_pkg" >/dev/null 2>&1 || ucode_pkg="!$ucode_pkg"
	elif command -v apt-get >/dev/null 2>&1; then
		ucode_pkg=$ucode_pkg_apt
		[ -z "$ucode_pkg" ] || dpkg -s "$ucode_pkg" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -y install "$ucode_pkg" >/dev/null 2>&1 || ucode_pkg="!$ucode_pkg"
	elif command -v pacman >/dev/null 2>&1; then
		ucode_pkg=$ucode_pkg_pacman
		[ -z "$ucode_pkg" ] || pacman -Q "$ucode_pkg" >/dev/null 2>&1 || pacman -S --needed --noconfirm "$ucode_pkg" >/dev/null 2>&1 || ucode_pkg="!$ucode_pkg"
	fi
	case $ucode_pkg in
	'') ;;
	!*) echo "xgs-linux-install: could not install CPU microcode package ${ucode_pkg#!}; install it manually" >&2 ;;
	*) say "CPU microcode package present: $ucode_pkg" ;;
	esac
fi
say "xgs-nat.service enabled: NAT/policy route out Port 2 (octep1) starts at boot"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
	# Default: only DHCP (udp 67) is allowed in on the LAN octeps; allow SSH etc. per trusted host yourself,
	# as docs/install-requirements.md describes. XGS_UFW_LAN_DHCP_ONLY=0 opens all inbound there (testing/assessment).
	say "ufw is active: allowing DHCP on the LAN octeps and all inbound on the management port"
	for i in 0 2 3 4 5 6 7 8 9; do
		if [ "${XGS_UFW_LAN_DHCP_ONLY:-1}" = 1 ]; then
			ufw allow in on octep$i proto udp to any port 67 >/dev/null && say "ufw: allow DHCP in on octep$i"
		else
			ufw allow in on octep$i >/dev/null && say "ufw: allow in on octep$i"
		fi
	done
	ufw allow in on enp2s0 >/dev/null && say "ufw: allow in on enp2s0"
	# Forwarded LAN traffic: ufw's FORWARD policy is drop by default
	if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
		for i in 0 2 3 4 5 6 7 8 9; do
			ufw route allow in on octep$i out on octep1 >/dev/null &&
				say "ufw: route octep$i -> octep1"
		done
	fi
	# The NPU is a separate Linux system with PCIe DMA into the host: on its link (mvmgmt0) only the
	# NPU address may reach the host's own link address; nothing else is accepted and nothing is
	# forwarded. XGS_UFW_NPU_ISOLATE=0 skips this; XGS_NPU_PORTS="22 ..." limits it to those tcp ports.
	if [ "${XGS_UFW_NPU_ISOLATE:-1}" = 1 ]; then
		npu_host=${NPU_HOST_ADDR:-169.254.254.1}
		npu_addr=${NPU_ADDR:-169.254.254.2}
		ufw route insert 1 deny in on mvmgmt0 >/dev/null && say "ufw: no forwarding from mvmgmt0"
		ufw insert 1 deny in on mvmgmt0 >/dev/null
		if [ -n "${XGS_NPU_PORTS:-}" ]; then
			for p in $XGS_NPU_PORTS; do
				ufw insert 1 allow in on mvmgmt0 proto tcp from "$npu_addr" to "$npu_host" port "$p" >/dev/null
			done
		else
			ufw insert 1 allow in on mvmgmt0 from "$npu_addr" to "$npu_host" >/dev/null
		fi
		say "ufw: mvmgmt0 accepts only $npu_addr -> $npu_host"
	fi
else
	say "ufw not active: no firewall rules added"
fi

echo ""
echo "xgs-linux-install: DONE. Summary:"
echo "xgs-linux-install: default NAT: all LAN ports routed via Port 2 (octep1); optional: $XGS_ROOT/scripts/nat/nat-port4.sh or nat-off.sh"
echo "xgs-linux-install: installed OCTEP for $KVER and enabled DKMS kernel-update builds"
echo "xgs-linux-install: loaded VFIO modules only; octep was not loaded or bound"
echo "xgs-linux-install: enabled boot-time OCTEP load, SDP ring bring-up, and front-port setup"
echo "xgs-linux-install: enabled 30-second status checks and retries until OCTEP bring-up succeeds"
echo "xgs-linux-install: enabled read-only PCI and serial-console health collection at boot and every five minutes"
echo "xgs-linux-install: scripts and controls installed under /usr/local/xgs/linux"
echo "xgs-linux-install: use sudo /usr/local/xgs/linux/scripts/octep/sdp-bringup.sh to manually arm rings"
echo "xgs-linux-install: use sudo /usr/local/xgs/linux/scripts/octep/sdp-ring-test.sh for a guarded ring reload test"
echo "xgs-linux-install: DKMS initramfs behavior follows system configuration; bootloader settings were not changed"
