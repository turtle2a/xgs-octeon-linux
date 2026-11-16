# Test rig NAT

The offload tests need the LAN client (`10.4.4.2`, behind `octep0`) to reach the server (`192.168.1.1`) through
`octep1`. Runtime iptables rules are lost on reboot, so `scripts/tests/xgs-test-masq.service` recreates them.

- **What it does:** `xgs-test-masq.sh` masquerades everything leaving the WAN adapters in table `ip xgsnat`. The adapters
  are `WAN_PORTS` in `/etc/xgs-nat.conf` (default `octep1 octep3`, ports 2 and 4); the rule matches by interface name, so adapters that do not exist yet (boot, driver reload) are fine, and IP forwarding is enabled.
  Example: `echo 'WAN_PORTS="octep1"' > /etc/xgs-nat.conf`.
- **Default:** on. Install and enable it once:

  ```
  install -D -m 0755 scripts/tests/xgs-test-masq.sh /usr/local/xgs/linux/scripts/tests/xgs-test-masq.sh
  install -m 0644 scripts/tests/xgs-test-masq.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now xgs-test-masq.service
  ```

- **Opt out (users who do not want NAT):** `touch /etc/xgs-nat-off`, then reboot or `systemctl stop xgs-test-masq`.
  Remove the file and run `systemctl start xgs-test-masq` to turn it back on.
- **Check:** `iptables -t nat -S XGS_MASQ` shows `-o <adapter> -j MASQUERADE` for each configured adapter.
- **Symptom when missing:** client SYNs leave `octep1` with a private source, conntrack shows `[UNREPLIED]`, and
  iperf never connects (live test 13).
- Test rig only. Never touch `enp2s0` (the management port); the rule only matches `octep1` and `octep3`.
