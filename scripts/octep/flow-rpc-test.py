#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Dry-run-first sender for the OCTEP flow RPC test interface."""

import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import os
from pathlib import Path
import sys


OPERATIONS = {
    "nhop": (6, 32),
    "mflow": (8, 32),
    "flow-create": (10, 180),
}
DEFAULT_LOG_DIR = Path(__file__).resolve().parents[2] / "tests"


def read_payload(args, expected_length):
    if args.payload_hex is not None:
        text = args.payload_hex
    else:
        try:
            text = args.payload_file.read_text(encoding="ascii")
        except (OSError, UnicodeError) as exc:
            raise ValueError(f"cannot read payload file: {exc}") from exc

    try:
        payload = bytes.fromhex(text)
    except ValueError as exc:
        raise ValueError(f"payload must contain hexadecimal bytes: {exc}") from exc
    if len(payload) != expected_length:
        raise ValueError(
            f"{args.operation} needs exactly {expected_length} bytes, got {len(payload)}"
        )
    return payload


def le(payload, offset, size):
    return int.from_bytes(payload[offset:offset + size], "little")


def ipv4(payload, offset):
    return str(ipaddress.IPv4Address(payload[offset:offset + 4]))


def decode_mflow(payload, offset, name):
    identity = le(payload, offset, 4)
    operation = le(payload, offset + 4, 4)
    behavior = le(payload, offset + 8, 4)
    revision = le(payload, offset + 16, 4)
    next_hop = le(payload, offset + 20, 4)
    return [
        f"  {name}.id={identity & 0x1ffffff} revision={(identity >> 25) & 0x3f} "
        f"valid={(identity >> 31) & 1}",
        f"  {name}.sa_index={operation & 0xffff} action={(operation >> 16) & 0xf} "
        f"direction={(operation >> 23) & 1} bridge_control={(operation >> 24) & 0xf} "
        f"state={(operation >> 28) & 0xf}",
        f"  {name}.dscp={(behavior >> 16) & 0xff} "
        f"dscp_enable={(behavior >> 24) & 1} l3_revision={behavior & 0xffff}",
        f"  {name}.connection={le(payload, offset + 12, 4)} "
        f"fw_revision={revision & 0xffff} connection_revision={revision >> 16}",
        f"  {name}.next_hop={next_hop & 0xffffff} next_hop_revision={next_hop >> 24} "
        f"sa_revision={le(payload, offset + 24, 2)} timeout={le(payload, offset + 28, 4)}",
    ]


def describe_payload(operation, payload):
    if operation == "nhop":
        return [
            "NHOP_PROGRAM payload:",
            f"  index={le(payload, 0, 4)} resolved={payload[4] & 1} revision={payload[5]}",
            f"  destination_mac={':'.join(f'{b:02x}' for b in payload[8:14])} "
            f"source_mac={':'.join(f'{b:02x}' for b in payload[14:20])}",
            f"  ethertype=0x{int.from_bytes(payload[20:22], 'big'):04x} "
            f"vlan={int.from_bytes(payload[22:24], 'big')} "
            f"tag={le(payload, 24, 2)} flags=0x{payload[26]:02x} "
            f"interface={payload[27]} mtu={le(payload, 28, 2)}",
        ]
    if operation == "mflow":
        return ["MFLOW_PROGRAM payload (updates one existing identity):"] + \
            decode_mflow(payload, 0, "mflow")

    conn_flags = le(payload, 4, 4)
    nat = payload[84:108]
    original_src_port = int.from_bytes(nat[18:20], "big")
    original_dst_port = int.from_bytes(nat[16:18], "big")
    translated_src_port = int.from_bytes(nat[22:24], "big")
    translated_dst_port = int.from_bytes(nat[20:22], "big")
    return [
        "FLOW_CREATE_FP payload:",
        f"  connection={le(payload, 0, 4)} revision={conn_flags & 0xffff} "
        f"dnat={(conn_flags >> 19) & 1} snat={(conn_flags >> 20) & 1} "
        f"verdict={(conn_flags >> 21) & 3} state={(conn_flags >> 30) & 3}",
        f"  live_user={le(payload, 8, 2)} session_revision={le(payload, 10, 2)} "
        f"session={le(payload, 12, 4)} tcp_block_nonzero={int(any(payload[24:84]))}",
        f"  original_src={ipv4(nat, 0)}:{original_src_port} "
        f"original_dst={ipv4(nat, 4)}:{original_dst_port}",
        f"  translated_src={ipv4(nat, 8)}:{translated_src_port} "
        f"translated_dst={ipv4(nat, 12)}:{translated_dst_port}",
        f"  direction_valid_mask=0x{le(payload, 112, 4):08x} "
        "(bit 0 original, bit 1 reply)",
        *decode_mflow(payload, 116, "original"),
        *decode_mflow(payload, 148, "reply"),
        "  note: this command needs a complete, valid connection and both flow identities; "
        "the script does not allocate them",
    ]


def require_writable_rpc(device):
    try:
        state = (device / "rpc_state").read_text(encoding="ascii")
    except OSError as exc:
        raise ValueError(f"cannot read rpc_state: {exc}") from exc

    fields = dict(item.split("=", 1) for item in state.split() if "=" in item)
    if fields.get("configured") != "1":
        raise ValueError("RPC is not configured")
    if fields.get("write_gate") != "1":
        raise ValueError("write gate is closed; explicitly set rpc_allow_write to 1")
    return state


def read_attribute(device, attribute):
    try:
        return (device / attribute).read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ValueError(f"cannot read {attribute}: {exc}") from exc


def write_attribute(device, attribute, value):
    try:
        with (device / attribute).open("w", encoding="ascii") as handle:
            handle.write(value + "\n")
    except OSError as exc:
        raise ValueError(f"sysfs write failed: {exc}") from exc


def log_path():
    override = os.environ.get("OCTEP_TEST_LOG")
    if override:
        return Path(override), True

    log_dir = Path(os.environ.get("OCTEP_TEST_LOG_DIR", DEFAULT_LOG_DIR))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return log_dir / f"flow-rpc-test-{stamp}.log", False


def write_log(path, records, append):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "x"
    with path.open(mode, encoding="utf-8") as handle:
        handle.write("\n".join(records) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)

    bump = subparsers.add_parser("revision-bump")
    bump.add_argument("--device", type=Path,
                      help="OCTEP PCI sysfs device directory")
    bump.add_argument("--apply", action="store_true",
                      help="send the state-changing command (default: dry run)")

    send = subparsers.add_parser("send")
    send.add_argument("operation", choices=OPERATIONS)
    send.add_argument("--device", type=Path,
                      help="OCTEP PCI sysfs device directory")
    payload_source = send.add_mutually_exclusive_group(required=True)
    payload_source.add_argument("--payload-hex")
    payload_source.add_argument("--payload-file", type=Path)
    send.add_argument("--apply", action="store_true",
                      help="send the state-changing command (default: dry run)")

    args = parser.parse_args()
    path, append = log_path()
    records = []

    def emit(message):
        line = f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {message}"
        print(line)
        records.append(line)

    result = "PASS" if args.apply else "DRY-RUN"
    try:
        source = Path(__file__).resolve()
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        emit(f"source_file={source}")
        emit(f"source_sha256={source_hash}")
        if args.apply and args.device is None:
            raise ValueError("--device is required with --apply")
        destination = str(args.device) if args.apply else "none (dry-run)"
        emit(f"action={args.action} apply={int(args.apply)} destination={destination}")
        if args.action == "revision-bump":
            if args.apply:
                state_before = require_writable_rpc(args.device)
                emit(f"rpc_state_before={state_before.strip()}")
                emit(f"rpc_last_before={read_attribute(args.device, 'rpc_last')}")
                write_attribute(args.device, "rpc_fw_rev_bump", "1")
                emit("revision bump sysfs write acknowledged")
                emit(f"rpc_state_after={read_attribute(args.device, 'rpc_state')}")
                emit(f"rpc_last_after={read_attribute(args.device, 'rpc_last')}")
            else:
                emit("RPC command=0 FW_STATE_REV_SET payload_len=2; the driver increments "
                     "its revision and the NPU invalidates existing offloaded flows")
                emit("DRY RUN: no device access or RPC write performed")
        else:
            command, expected_length = OPERATIONS[args.operation]
            payload = read_payload(args, expected_length)
            command_name = {
                "nhop": "NHOP_PROGRAM",
                "mflow": "MFLOW_PROGRAM",
                "flow-create": "FLOW_CREATE_FP",
            }[args.operation]
            emit(f"operation={args.operation} command={command} ({command_name}) "
                 f"payload_len={len(payload)}")
            for line in describe_payload(args.operation, payload):
                emit(line)
            emit(f"payload_hex={payload.hex()}")
            if args.apply:
                state_before = require_writable_rpc(args.device)
                emit(f"rpc_state_before={state_before.strip()}")
                emit(f"rpc_last_before={read_attribute(args.device, 'rpc_last')}")
                write_attribute(args.device, "rpc_flow_write",
                                f"{command} {payload.hex()}")
                emit("RPC sysfs write acknowledged")
                emit(f"rpc_state_after={read_attribute(args.device, 'rpc_state')}")
                emit(f"rpc_last_after={read_attribute(args.device, 'rpc_last')}")
            else:
                emit("DRY RUN: no device access or RPC write performed")
    except ValueError as exc:
        result = "FAIL"
        emit(f"error: {exc}")
    emit(f"result={result}")
    emit(f"log_file={path}")
    try:
        write_log(path, records, append)
    except OSError as exc:
        print(f"error: could not write test log {path}: {exc}", file=sys.stderr)
        return 1

    return 0 if result in ("PASS", "DRY-RUN") else 1


if __name__ == "__main__":
    sys.exit(main())
