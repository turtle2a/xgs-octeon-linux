# Performance Testing and Scripts

Brief summary of each test script in [`scripts/tests/`](../scripts/tests/). All need root on the
appliance. Confirm offload is on first (`offload` sysfs shows `requested=on`).

```
scripts/tests/
  octep-offload-check.sh            offload check: runs the hook, prints a one-page AGREE/DISAGREE verdict.
                                    Start iperf3 from the LAN client at READY.
  octep-offload-check_octep0_1.sh   same check preset for octep0 (LAN) / octep1 (WAN), 30 s.
  octep-offload-check_octep2_to_11.sh  same check for the other port pairs; missing pairs are skipped.
  offload_check_live_with_cutin_at10.sh  check with a staged cut-in: host forwards first, NPU after 10 s.
  octep-offload-last.sh             re-prints the last run's summary; runs nothing.
  octep-hook-live.sh                live flowtable hook test on a LAN/WAN pair, then tears down.
  octep-iperf-gate.sh               iperf3 with the offload gate off, on (no flow) and off again.
  octep-tcp-offload.sh              iperf3 through one port while the agent runs; per-interval throughput.
  octep-nat-offload.sh              NAT offload on one port (SNAT, optional DNAT) from conntrack.
  octep-offload-commission.py       one bounded flow-create cycle on one port; checks the readback.
  octep-offload-loop.sh             read-only cycle: drives traffic, reads each live microflow.
  octep-frame-ident.py              classifies one flow's segments from LAN/WAN pcaps.
  octep-opcode-scan.sh              idle scan of unassigned RPC opcodes the firmware answers.
  octep-accel-telemetry-test.sh     reads NPU uptime, load and temperature over the management link.
  octep-fastdeploy.sh               swaps in a built octep.ko, reloads, rolls back on failure.
  xgs-auto-update-test.sh           stub test of the auto-update script and cron block; changes nothing.
```

Typical run: `sudo ./scripts/tests/octep-offload-check_octep0_1.sh 30`, then
`iperf3 -B <lan-client-ip> -c <wan-server-ip> -t 30` from the LAN client.

Exit codes of the offload check: 0 = CROSS-CHECK AGREE, 1 = DISAGREE or no valid run, 2 = could not run.
