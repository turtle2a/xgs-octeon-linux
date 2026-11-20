# Appliance directory

> **Disclaimer.** Generated from the vendor appliance property spec files. Only the XGS 2300 is tested; every other entry is an inference. Hardware with a similar name may differ in wiring, PCI IDs and firmware. Use at your own risk; not affiliated with any vendor.

## NPU appliances possibly suitable for this install

Only appliances whose spec file reports an OCTEON NPU. Armada (20 files) is not expected to work and the 95 no-NPU files are out of scope; both are in their folders below.

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

One folder per NPU type, one file per spec. Overview: [compatible-appliances](../docs/compatible-appliances.md), [tree view](../docs/appliance-tree.md).

| Folder | NPU | Files |
|---|---|---|
| [`octeon-tx/`](octeon-tx/) | OCTEON TX (most likely) | 4 |
| [`octeon-tx2/`](octeon-tx2/) | OCTEON TX2 (unknown) | 17 |
| [`octeon-tx2-98xx/`](octeon-tx2-98xx/) | OCTEON TX2 98xx (unknown) | 2 |
| [`armada/`](armada/) | Armada (not expected) | 20 |
| [`no-npu/`](no-npu/) | No NPU (out of scope) | 95 |
