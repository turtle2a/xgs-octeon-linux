# OCTEP Diagnostics and Debugging

This guide covers optional runtime diagnostics. Dynamic debug is not required
to build or run OCTEP.

## Record the Kernel and Module

Capture the running kernel release and the module selected for the next load:

```sh
uname -r
modinfo -n octep
modinfo -F vermagic octep
dkms status -m xgs-octep -k "$(uname -r)"
```

The module file on disk may differ from the driver already loaded in memory
until the module is loaded again or the system reboots.

## Capture Kernel Logs

Show this boot's kernel messages:

```sh
sudo journalctl -k -b -o short-monotonic --no-pager
```

Follow new kernel messages while reproducing an issue:

```sh
sudo journalctl -k -b -f
```

For local filtering, useful terms include `octep`, `mailbox`, `sriov`,
`handshake`, `rpc`, and `NWA`. Keep local diagnostic logs unchanged; scrub
host-specific or sensitive details before sharing them on GitHub.

## Enable Dynamic Debug

Dynamic debug is optional and requires a kernel built with
`CONFIG_DYNAMIC_DEBUG=y` (and, where applicable,
`CONFIG_DYNAMIC_DEBUG_CORE=y`). Check the active kernel configuration with:

```sh
grep -E '^CONFIG_DYNAMIC_DEBUG(=|_)' "/boot/config-$(uname -r)"
```

If debugfs is not already mounted, mount it and enable OCTEP debug callsites:

```sh
if ! mountpoint -q /sys/kernel/debug; then
  sudo mount -t debugfs debugfs /sys/kernel/debug
fi
printf 'module octep +p\n' |
  sudo tee /sys/kernel/debug/dynamic_debug/control
```

Run this after OCTEP is loaded and before reproducing the mailbox issue. The
current VF mailbox implementation uses `dev_dbg` for unsupported opcodes
(NACKs); its probe, handshake, and initial mailbox activity already use
`dev_info` messages. Dynamic debug does not enable logging for each ACK.

## Preserve the Live NPU

Do not unbind or reload the OCTEP driver while SDP rings are armed, the
handshake is complete, or front-port netdevs are present. Check the driver's
`sdp_state` first and use the guarded test script's preflight before disruptive
testing.

## Automatic Recovery of a Blocked NPU

The root-run `xgs-octep-sdp-status.timer` invokes the status checker, which
automatically calls `scripts/octep/sdp-recover-npu.sh` only for the known
blocked state: rings stopped, handshake idle, packet service disabled, no
front-port netdevs, and scratch `0x1` or `0x1f` (the two observed states). It
also requires the tested topology (`0000:01:00.0` behind `0000:00:01.1`, alone
on bus 01) and an available PCI bus-reset method. The enabled root timer checks
every 30 seconds from startup and remains active after recovery or a temporary
PF unbind; no user `sudo -i` session is needed. The checker inspects SDP sysfs
state even if systemd reports the oneshot bring-up unit as `active (exited)`.

The original incident was observed during an acceleration/flow-telemetry
driver test that reloaded OCTEP; afterward host SDP state was stopped/idle
while target-owned scratch remained `0x1f`. Treat this as the observed trigger,
not proof that every driver reload causes this state.

The corresponding kernel-log signature was:

```text
xgs-npu-health: ERROR: SDP rings are stopped; armed rings were required
xgs-octep-bringup: ERROR: target-owned handshake scratch is 0x000000000000001f; refusing to reprogram rings
xgs-accel-status: ERROR: SDP packet path is not ready (rings=stopped, ring_count=0, handshake=idle, service=disabled)
```

Health errors then repeated about every 330 seconds. Use these messages to
recognize the incident in logs; automated recovery checks the matching PCI
sysfs state and does not depend on parsing dmesg.

The helper stops bring-up, performs the same guarded bus-reset sequence used
for manual recovery, rebinds OCTEP, waits for scratch to clear, and starts the
normal bring-up service. It verifies armed rings, completed handshake, and
active packet service, then restores DHCP on `octep1` through NetworkManager
without explicitly disconnecting the interface. Existing default-route policy
is preserved; a newly created DHCP profile does not install a default route.
The DHCP activation uses `nmcli --wait 0 connection up` so a missing lease
does not block the status check. If a lease is still missing, the helper
retries activation every 60 seconds and only cycles each interface once.
NetworkManager's cloned-MAC setting is preserved by recovery. In the observed
port 2 test, manually changing the profile from `Stable` to `Permanent` was
followed by a DHCP lease on `octep1` and a successful gateway ping; match this
setting to the DHCP server's expected client identity when diagnosing leases.

The recovery attempt and result are recorded in the systemd journal. A reset
guard prevents repeated resets while an incident remains unresolved; once the
full healthy state is confirmed, the guard is cleared so a later distinct
failure can be recovered in the same boot. Other scratch values and unsafe
topologies are refused and logged. The reset briefly interrupts NPU interfaces
but does not reboot the host.

Do not broaden the trigger to arbitrary scratch values or live ring states.
Other topologies and scratch states require manual investigation. Do not clear
the target-owned scratch register, toggle PCI `enable`, or force D3cold; those
actions are not equivalent to this reset.

When sharing environment details, include the kernel release and only relevant
configuration lines; the full kernel `.config` is not an OCTEP build
requirement.
