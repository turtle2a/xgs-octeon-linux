# NPU flow offload (opt-in, experimental)

Offload is **off** by default (`flow_offload=N`). Enable it for testing only with
`scripts/octep/offload-enable.sh`; check it with `scripts/octep/offload-check.sh`.
It does not change install, NAT, DHCP, firewall or routing.

## Status (Task 9)

Overall about 62%. Item 7 (a NAT'd TCP flow forwarded by the NPU) is about 40%:

- A conntrack-approved TCP flow is programmed through the flowtable hook (next
  hops, then `FLOW_CREATE_FP`). Firmware accepts every write.
- `ft_two_step=Y` follows the Sophos `sp2fp` order: the flow-create carries the
  live direction only and the other microflow follows by `MFLOW_PROGRAM`
  (`ft_two_step_ms` delays that second write). Unmodified `iperf3 -t 60`
  through the NAT: **62 retries at 368 Mbit/s**, against 106-409 before, and
  under the 72-retry bar.
- Not met: the NPU still forwards nothing (`WIRE_TO_WIRE=0`, every frame counted
  `MFLOW_NOT_ACTIVE`), so traffic runs on the host path and the stall guard
  releases the flow about 200 ms after offload.

Test knobs (all default off, under `/sys/module/octep/parameters/`) cover the
guard window, reply-path revisions, TCP state and direction handling. Each has a
one-line description in `modinfo octep`.
