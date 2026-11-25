# Appliance directory

> **Disclaimer.** Generated from the vendor appliance property spec files. Only the XGS 2300 is tested; every other entry is an inference. Hardware with a similar name may differ in wiring, PCI IDs and firmware. Use at your own risk; not affiliated with any vendor.

## NPU appliances possibly suitable for this install

Only appliances whose spec file reports an OCTEON NPU. Armada has its own table below; the 95 no-NPU files are out of scope. Both are in their folders.

| Model | NPU | Cores | RAM | Port layout | Likelihood | Spec |
|---|---|---|---|---|---|---|
| XGS2100 | OCTEON_TX | 4 | 8GB | `Port8_F2MA` | 🟡 Most likely (same family as tested) | [file](octeon-tx/xgs2100_rl01.md) |
| XGS2300 | OCTEON_TX | 4 | 8GB | `Port8_F2MA` | ✅ **Tested** | [file](octeon-tx/xgs2300_rl01.md) |
| XGS3100 | OCTEON_TX | 4 | 12GB | `Port8_F4MA` | 🟡 Most likely (same family as tested) | [file](octeon-tx/xgs3100_rl01.md) |
| XGS3300 | OCTEON_TX | 8 | 16GB | `Port8_F4MA` | 🟡 Most likely (same family as tested) | [file](octeon-tx/xgs3300_rl01.md) |
| XGS4300 | OCTEON_TX2 | 12 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4300_am01.md) |
| XGS4300 | OCTEON_TX2 | 12 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4300_am03.md) |
| XGS4300 | OCTEON_TX2 | 12 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4300_am02.md) |
| XGS4380 | OCTEON_TX2 | 12 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4380_am01.md) |
| XGS4500 | OCTEON_TX2 | 16 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4500_am01.md) |
| XGS4500 | OCTEON_TX2 | 16 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4500_am02.md) |
| XGS4500 | OCTEON_TX2 | 16 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4500_am03.md) |
| XGS4580 | OCTEON_TX2 | 16 | 32GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs4580_am01.md) |
| XGS5500 | OCTEON_TX2 | 32 | 64GB | `Port8_F8MAB_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs5500_ci02.md) |
| XGS5500 | OCTEON_TX2 | 32 | 64GB | `Port8_F8MAB_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs5500_ci01.md) |
| XGS5510 | OCTEON_TX2 | 24 | 96GB | `Port6_F12MAB_QSFP2_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs5510_ci01.md) |
| XGS5580 | OCTEON_TX2 | 24 | 64GB | `Port8_F4MAB` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs5580_am01.md) |
| XGS6500 | OCTEON_TX2 | 48 | 80GB | `Port8_F12MAB_N2` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs6500_ci02.md) |
| XGS6500 | OCTEON_TX2 | 48 | 80GB | `Port8_F12MAB_N2` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs6500_ci01.md) |
| XGS6510 | OCTEON_TX2 | 48 | 192GB | `Port6_F12MAB_QSFP2_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs6510_ci01.md) |
| XGS6580 | OCTEON_TX2 | 48 | 96GB | `Port6_F12MAB_QSFP2_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs6580_ci01.md) |
| XGS7580 | OCTEON_TX2 | 64 | 192GB | `Port6_F12MAB_QSFP2_N1` | ⚪ Unknown (newer generation) | [file](octeon-tx2/xgs7580_ci01.md) |
| XGS7500 | OCTEON_TX2_98XX | 64 | 128GB | `Port8_F14MAB_N2` | ⚪ Unknown (high end) | [file](octeon-tx2-98xx/xgs7500_ci01.md) |
| XGS8500 | OCTEON_TX2_98XX | 128 | 256GB | `Port8_F14MAB_N2` | ⚪ Unknown (high end) | [file](octeon-tx2-98xx/xgs8500_ci01.md) |

## Armada appliances: installer option available, not validated

The installer detects the Marvell Armada PCIe endpoint (`11ab:7080`) and, with `--allow-untested-platform`, continues. Nothing here is validated; the Armada vendor drivers (`mv_armada_drv` and others) are not part of this project, so the NPU ports will not appear.

| Model | Cores | RAM | Port layout | Status | Spec |
|---|---|---|---|---|---|
| XGS107 | 2 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs107_sn01.md) |
| XGS107w | 2 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs107w_sn01.md) |
| XGS116 | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116_xn01.md) |
| XGS116 | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116_xn02.md) |
| XGS116w-VCR | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116w-vcr_xn01.md) |
| XGS116w-VCR | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116w-vcr_xn02.md) |
| XGS116w | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116w_xn01.md) |
| XGS116w | 4 | 4GB | `Port8_F1` | 🟡 Option available, not validated | [file](armada/xgs116w_xn02.md) |
| XGS126 | 4 | 6GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs126_xn01.md) |
| XGS126 | 4 | 6GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs126_xn02.md) |
| XGS126w | 4 | 6GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs126w_xn01.md) |
| XGS126w | 4 | 6GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs126w_xn02.md) |
| XGS136 | 4 | 8GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs136_xn01.md) |
| XGS136 | 4 | 8GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs136_xn02.md) |
| XGS136w | 4 | 8GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs136w_xn01.md) |
| XGS136w | 4 | 8GB | `Port12_F2` | 🟡 Option available, not validated | [file](armada/xgs136w_xn02.md) |
| XGS138 | 4 | 8GB | `Port6_F2` | 🟡 Option available, not validated | [file](armada/xgs138_xn01.md) |
| XGS138 | 4 | 8GB | `Port6_F2` | 🟡 Option available, not validated | [file](armada/xgs138_xn02.md) |
| XGS87 | 2 | 4GB | `Port4_F1` | 🟡 Option available, not validated | [file](armada/xgs87_sn01.md) |
| XGS87w | 2 | 4GB | `Port4_F1` | 🟡 Option available, not validated | [file](armada/xgs87w_sn01.md) |

Installing on a non-OCTEON-TX appliance: `install.sh` stops with a disclaimer unless you pass `--allow-untested-platform` (untested; see [compatible-appliances](../docs/compatible-appliances.md)).

One folder per NPU type, one file per spec. Overview: [compatible-appliances](../docs/compatible-appliances.md), [tree view](../docs/appliance-tree.md).

| Folder | NPU | Files |
|---|---|---|
| [`octeon-tx/`](octeon-tx/) | OCTEON TX (most likely) | 4 |
| [`octeon-tx2/`](octeon-tx2/) | OCTEON TX2 (unknown) | 17 |
| [`octeon-tx2-98xx/`](octeon-tx2-98xx/) | OCTEON TX2 98xx (unknown) | 2 |
| [`armada/`](armada/) | Armada (option available, not validated) | 20 |
| [`no-npu/`](no-npu/) | No NPU (out of scope) | 95 |
