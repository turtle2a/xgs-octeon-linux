# Appliances that may be compatible (Task 10a)

> **Disclaimer.** This project is verified on **one** appliance only: an XGS 2300
> (OCTEON TX, CN83xx family). Everything else in this table is an *inference from
> the vendor appliance property spec files*, not a test result. Hardware with a
> similar name can use different switch wiring, PCI IDs and firmware. Do not run
> the installer on hardware you cannot recover, and test at your own risk. This
> project is not affiliated with or endorsed by any appliance vendor.

Full list of all 138 spec files as a tree: [appliance-tree.md](appliance-tree.md). Browsable folders, one file per spec: [`appliances/`](../appliances/).

## How this was derived

The firmware property file for each appliance has an `NPU=` field. The 138 spec
files fall into these groups:

| `NPU=` value | Files | Meaning for this project |
|---|---|---|
| `NO` | 95 | x86 appliances and virtual images. Out of scope (no NPU). |
| `ARMADA` | 20 | Marvell Armada SoC with its own switch. A different design from the OCTEON PCIe NPU. Not expected to work. |
| `OCTEON_TX` | 4 | Same family as the tested XGS 2300. Most likely to work. |
| `OCTEON_TX2` | 17 | Newer OCTEON TX2. Different generation; unknown. |
| `OCTEON_TX2_98XX` | 2 | OCTEON TX2 98xx, high end. Different generation; unknown. |

## OCTEON TX (same family as the tested unit)

| Model | CPU cores | RAM | Port layout (spec string) | Status |
|---|---|---|---|---|
| XGS 2100 | 4 | 8 GB | `Port8_F2MA` | Untested. Same NPU family as the tested XGS 2300. |
| **XGS 2300** | 4 | 8 GB | `Port8_F2MA` | **Tested.** Copper ports work. NAT'd offload does not (item 7). SFP cages are not working (task 9c). |
| XGS 3100 | 4 | 12 GB | `Port8_F4MA` | Untested. |
| XGS 3300 | 8 | 16 GB | `Port8_F4MA` | Untested. |

## OCTEON TX2 and TX2 98xx (unknown)

| Model | CPU cores | RAM |
|---|---|---|
| XGS 4300 | 12 | 32 GB |
| XGS 4380 | 12 | 32 GB |
| XGS 4500 | 16 | 32 GB |
| XGS 4580 | 16 | 32 GB |
| XGS 5500 | 32 | 64 GB |
| XGS 5510 | 24 | 96 GB |
| XGS 5580 | 24 | 64 GB |
| XGS 6500 | 48 | 80 GB |
| XGS 6510 | 48 | 192 GB |
| XGS 6580 | 48 | 96 GB |
| XGS 7580 | 64 | 192 GB |
| XGS 7500 (98xx) | 64 | 128 GB |
| XGS 8500 (98xx) | 128 | 256 GB |

## Armada (not expected to work)

XGS 87, 87w, 107, 107w, 116, 116w, 126, 126w, 136, 136w and 138, plus the
116w VCR variants. These use `NPU=ARMADA`, which is not the OCTEON PCIe NPU this
driver targets.

## Reading the port layout string

`PortN_Fx` is the number of copper ports (`N`) and fibre or SFP ports (`x`), for
example `Port8_F2MA` is 8 copper plus 2 fibre. On the tested XGS 2300 the firmware
reports 12 NetAgent ports. Ten become `octep0` to `octep9`. How the fibre cages map
to those netdevs is still being verified (task 9c).

## Help wanted

If you test another model, please report the PCI ID (`lspci -nn | grep 177d`), the
kernel log from `octep` probe, and whether `octep0` to `octep9` appear. Remove
serial numbers and MAC addresses before posting.
