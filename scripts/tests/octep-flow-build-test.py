#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2] / "scripts/octep"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load("flow_build", "flow-build.py")
decode = load("flow_rpc_test", "flow-rpc-test.py")

SPEC = {
    "conn_idx": 7, "conn_rev": 3, "fw_rev": 5, "l3_rev": 9,
    "orig": {"id": 62, "rev": 0, "nhop": {
        "index": 9, "rev": 1, "dst": "02:00:00:00:00:00",
        "src": "02:00:00:00:01:0X", "iface": 10, "tag": 33792, "mtu": 1500}},
    "reply": {"id": 63, "rev": 2, "nhop": {
        "index": 10, "rev": 4, "dst": "02:00:00:00:00:01",
        "src": "02:00:00:00:01:0X", "iface": 3, "tag": 33280, "mtu": 1500}},
}


class FlowBuildTest(unittest.TestCase):
    def test_lengths_and_commands(self):
        lines = build.build(SPEC)
        self.assertEqual([c for c, _ in lines], [6, 6, 10])
        self.assertEqual([len(p) for _, p in lines], [32, 32, 180])

    def test_flow_decodes_as_both_directions_active(self):
        payload = build.build(SPEC)[2][1]
        self.assertEqual(int.from_bytes(payload[112:116], "little"), 3)
        text = "\n".join(decode.decode_mflow(payload, 116, "o") +
                         decode.decode_mflow(payload, 148, "r"))
        for expect in ("o.id=62 revision=0 valid=1", "r.id=63 revision=2 valid=1",
                       "o.sa_index=0 action=1 direction=0", "r.sa_index=0 action=1 direction=1",
                       "state=2", "o.connection=7 fw_revision=5 connection_revision=3",
                       "o.next_hop=9 next_hop_revision=1", "r.next_hop=10 next_hop_revision=4"):
            self.assertIn(expect, text)
        flags = int.from_bytes(payload[4:8], "little")
        self.assertEqual(flags >> 30, 1)
        self.assertEqual(flags & 0xffff, 3)

    def test_nhop_decodes(self):
        payload = build.build(SPEC)[0][1]
        text = "\n".join(decode.describe_payload("nhop", payload))
        self.assertIn("index=9 resolved=1 revision=1", text)
        self.assertIn("destination_mac=02:00:00:00:00:00 source_mac=02:00:00:00:01:0X", text)
        self.assertIn("ethertype=0x0800", text)
        self.assertIn("interface=10 mtu=1500", text)

    def test_rejects_unsafe_specs(self):
        same = dict(SPEC, reply=dict(SPEC["reply"], id=62))
        with self.assertRaises(ValueError):
            build.flow_create(same)
        with self.assertRaises(ValueError):
            build.flow_create(dict(SPEC, conn_idx=1))


if __name__ == "__main__":
    unittest.main()
