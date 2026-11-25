#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Stub-based test of xgs-auto-update.sh and the installer's cron block, including induced
# failures (no package manager, failing installs, disabled marker). Needs `unshare -r`; changes nothing.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UPD=$ROOT/scripts/xgs/xgs-auto-update.sh
UNSHARE=$(command -v unshare) || [ "$(id -u)" -eq 0 ] || { echo "SKIP: unshare not found"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

mkbin() { # dir tool...
	mkdir -p "$1/bin"
	d=$1
	shift
	for c in awk grep tr date id flock sh cat echo sed; do ln -sf "$(command -v $c)" "$d/bin/$c"; done
	: >"$d/calls"
}
stub() { # dir name [exit] [stdout]
	printf '#!/bin/sh\necho "%s $*" >>%s/calls\n%s\nexit %s\n' "$2" "$1" "${4:-}" "${3:-0}" >"$1/bin/$2"
	chmod +x "$1/bin/$2"
}
runupd() { # dir [VAR=val...]
	d=$1
	shift
	(
		PATH="$d/bin"
		XGS_UPDATE_LOG="$d/log"
		XGS_UPDATE_LOCK="$d/lock"
		export PATH XGS_UPDATE_LOG XGS_UPDATE_LOCK
		for kv in "$@"; do export "$kv"; done
		runroot "$UPD"
	)
}
runroot() { # run a script as uid 0 (already root, or via a user namespace)
	if [ "$(id -u)" -eq 0 ]; then /bin/sh "$1"; else "$UNSHARE" -r /bin/sh "$1"; fi
}

# dnf: kernels included by default, noninteractive; DNF_EXCLUDE in the conf holds them back
D=$T/dnf; mkbin $D; stub $D dnf
runupd $D; ! grep -q -- "--exclude" $D/calls && grep -q -- " -y " $D/calls && ok "dnf includes kernel, -y" || bad "dnf args"
D=$T/dnf2; mkbin $D; stub $D dnf
runupd $D "DNF_EXCLUDE=kernel*"; grep -q -- "--exclude=kernel\*" $D/calls && ok "dnf conf can hold kernel" || bad "dnf conf hold"

# apt: kernel packages included by default
D=$T/apt; mkbin $D; stub $D apt-get 0 'case " $* " in *" -s "*) printf "Inst bash [1]\nInst linux-image-6.1 [1]\nInst curl [1]\n";; esac'
runupd $D
grep -q "install --only-upgrade bash linux-image-6.1 curl" $D/calls && ok "apt includes kernel" || bad "apt kernel included"

# pacman: full sync, nothing ignored by default
D=$T/pac; mkbin $D; stub $D pacman
runupd $D; grep -q "pacman -Syu --noconfirm" $D/calls && ! grep -q -- "--ignore" $D/calls && ok "pacman -Syu, no ignore" || bad "pacman args"

# induced: no package manager -> exit 1, logged
D=$T/none; mkbin $D
runupd $D; rc=$?
[ $rc -eq 1 ] && grep -q "no supported package manager" $D/log && ok "no package manager: logged, rc=1" || bad "no-pm handling (rc=$rc)"

# induced: package manager fails -> rc propagated, no reboot, logged
D=$T/fail; mkbin $D; stub $D dnf 7
runupd $D; rc=$?
[ $rc -eq 7 ] && grep -q "finished rc=7" $D/log && ok "failure propagated (rc=7), logged" || bad "failure propagation (rc=$rc)"

# installer cron block: unsupported system and failing installs must never abort (set -eu)
BLOCK=$T/block.sh
sed -n '/^cron_unit=$/,/^say "xgs-nat.service enabled/p' "$ROOT/install.sh" | sed '$d' >"$BLOCK"
[ -s "$BLOCK" ] && grep -q "Unattended updates (cron)" "$BLOCK" || { echo "FAIL: install.sh has no cron block (old install.sh?)"; exit 1; }
cron_case() { # name tools... ; systemctl always "no unit"
	n=$1
	shift
	D=$T/c_$n; mkbin $D
	ln -sf "$(command -v true)" $D/bin/true
	for t in "$@"; do stub $D "$t" 1; done
	stub $D systemctl 1
	printf 'set -eu\nXGS_ROOT=/x\nstep(){ echo "STEP $*"; }\nsay(){ echo "say $*"; }\n. %s\necho REACHED_END\n' "$BLOCK" >$D/run.sh
	out=$(PATH=$D/bin /bin/sh $D/run.sh 2>&1); rc=$?
	echo "$out" | grep -q REACHED_END && [ $rc -eq 0 ] && ok "installer continues: $n" || { bad "installer aborted: $n (rc=$rc)"; echo "$out"; }
	echo "$out" | grep -q "STEP Unattended updates" && ok "installer echoes step: $n" || bad "no echo: $n"
}
cron_case nopm
cron_case dnf_fails dnf
cron_case apt_fails apt-get
cron_case pacman_fails pacman

echo "failures: $fails"
[ "$fails" -eq 0 ]
