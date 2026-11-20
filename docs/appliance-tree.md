# Appliance tree (from the vendor property spec files)

> **Disclaimer.** Inferred from the `NPU=` field of 138 vendor spec files, not tested. Only the XGS 2300 is verified. See [compatible-appliances.md](compatible-appliances.md) for the reasoning and table. Hardware with a similar name may differ in wiring, PCI IDs and firmware. Use at your own risk; not affiliated with any vendor.

Each entry: `model  cores/RAM  port layout`. The model name is the spec file's `CRMODEL` value. `**` marks the tested unit.

```
OCTEON TX  (same family as the tested XGS 2300) - most likely to work  (4 spec files)
└── series XGXXP
    ├── XGS2100  4c/8GB  Port8_F2MA
    ├── XGS2300 **  4c/8GB  Port8_F2MA
    ├── XGS3100  4c/12GB  Port8_F4MA
    └── XGS3300  8c/16GB  Port8_F4MA

OCTEON TX2  (newer generation) - unknown  (17 spec files)
└── series XGXXP
    ├── XGS4300  12c/32GB  Port8_F4MAB
    ├── XGS4380  12c/32GB  Port8_F4MAB
    ├── XGS4500  16c/32GB  Port8_F4MAB
    ├── XGS4580  16c/32GB  Port8_F4MAB
    ├── XGS5500  32c/64GB  Port8_F8MAB_N1
    ├── XGS5510  24c/96GB  Port6_F12MAB_QSFP2_N1
    ├── XGS5580  24c/64GB  Port8_F4MAB
    ├── XGS6500  48c/80GB  Port8_F12MAB_N2
    ├── XGS6510  48c/192GB  Port6_F12MAB_QSFP2_N1
    ├── XGS6580  48c/96GB  Port6_F12MAB_QSFP2_N1
    └── XGS7580  64c/192GB  Port6_F12MAB_QSFP2_N1

OCTEON TX2 98xx  (high end) - unknown  (2 spec files)
└── series XGXXP
    ├── XGS7500  64c/128GB  Port8_F14MAB_N2
    └── XGS8500  128c/256GB  Port8_F14MAB_N2

Armada  (Marvell PCIe endpoint, different design) - installer option available, not validated  (20 spec files)
├── series CRING
│   ├── XGS87  2c/4GB  Port4_F1
│   ├── XGS107  2c/4GB  Port8_F1
│   ├── XGS116  4c/4GB  Port8_F1
│   ├── XGS126  4c/6GB  Port12_F2
│   ├── XGS136  4c/8GB  Port12_F2
│   └── XGS138  4c/8GB  Port6_F2
├── series CRWING
│   ├── XGS87w  2c/4GB  Port4_F1
│   ├── XGS107w  2c/4GB  Port8_F1
│   ├── XGS116w  4c/4GB  Port8_F1
│   ├── XGS126w  4c/6GB  Port12_F2
│   └── XGS136w  4c/8GB  Port12_F2
└── series VCRWING
    └── XGS116w-VCR  4c/4GB  Port8_F1

No NPU  (x86 appliances and virtual images) - out of scope  (95 spec files)
├── series CRAMI
│   └── SF01V  1c/4GB  PORT_A-Z
├── series CRAZU
│   └── SF01V  1c/4GB  PORT_A-Z
├── series CRING
│   ├── XG86  2c/4GB  PORT_1-4
│   ├── SF01V  1c/4GB  PORT_1-42
│   ├── SG115  2c/4GB  eth_0-3
│   ├── SG115  4c/4GB  eth_0-3
│   ├── SG125  2c/4GB  eth_0-7
│   ├── SG125  4c/4GB  eth_0-8
│   ├── SG135  4c/6GB  eth_0-7
│   ├── SG135  4c/6GB  eth_0-8
│   ├── XG106  2c/4GB  PORT_1-4
│   ├── XG115  2c/4GB  PORT_1-4
│   ├── XG115  4c/4GB  PORT_1-4
│   ├── XG125  4c/4GB  PORT_1-9
│   ├── XG125  2c/4GB  PORT_1-8
│   ├── XG135  4c/6GB  PORT_1-8
│   ├── XG135  4c/6GB  PORT_1-9
│   ├── XGS88  2c/4GB  Port4
│   ├── XG125a  2c/4GB  PORT_1-8
│   ├── XGS108  2c/6GB  Port6_F1
│   ├── XGS118  4c/8GB  Port9_F1
│   └── XGS128  4c/8GB  Port9_F1
├── series CRIVM
│   └── SF01V  1c/4GB  PORT_A-Z
├── series CRWING
│   ├── XG86w  2c/4GB  PORT_1-4
│   ├── SG115w  2c/4GB  eth_0-3
│   ├── SG115w  4c/4GB  eth_0-3
│   ├── SG125w  2c/4GB  eth_0-7
│   ├── SG125w  4c/4GB  eth_0-8
│   ├── SG135w  4c/6GB  eth_0-7
│   ├── SG135w  4c/6GB  eth_0-8
│   ├── XG106w  2c/4GB  PORT_1-4
│   ├── XG115w  2c/4GB  PORT_1-4
│   ├── XG115w  4c/4GB  PORT_1-4
│   ├── XG125w  4c/4GB  PORT_1-9
│   ├── XG125w  2c/4GB  PORT_1-8
│   ├── XG135w  4c/6GB  PORT_1-8
│   ├── XG135w  4c/6GB  PORT_1-9
│   ├── XGS88w  2c/4GB  Port4
│   ├── XGS108w  2c/6GB  Port6_F1
│   ├── XGS118w  4c/8GB  Port9_F1
│   └── XGS128w  4c/8GB  Port9_F1
├── series DUMMYOEM
│   └── DU01V  1c/4GB  NOLIMIT
├── series KMWVM
│   └── KM01V  1c/4GB  NOLIMIT
├── series SGXXP
│   ├── SG210  2c/8GB  E7_Port8
│   ├── SG210  2c/8GB  E5_Port8
│   ├── SG230  2c/8GB  E7_Port8
│   ├── SG230  2c/8GB  E5_Port8
│   ├── SG310  4c/12GB  E11_Port8
│   ├── SG310  4c/12GB  E9_Port8
│   ├── SG330  4c/12GB  E9_Port8
│   ├── SG330  4c/12GB  E11_Port8
│   ├── SG430  4c/16GB  A8_B8_C8_M1
│   ├── SG430  4c/16GB  E9_A8_B8
│   ├── SG450  8c/16GB  A8_B8_C8_M1
│   ├── SG450  8c/16GB  E9_A8_B8
│   ├── SG550  32c/24GB  A8_B8_C8_D8_M2
│   ├── SG550  24c/24GB  A8_B8_C8_M2
│   ├── SG650  40c/48GB  A8_F8_M2
│   └── SG650  40c/48GB  A8_B8_C8_D8_M2
├── series VCRING
│   └── VCR01V  1c/4GB  PORT_1-42
├── series VCRWING
│   └── XG115w-VCR  2c/4GB  PORT_1-4
└── series XGXXP
    ├── XG210  2c/8GB  8_PortA8
    ├── XG210  2c/8GB  6_PortA8
    ├── XG230  2c/8GB  8_PortA8
    ├── XG230  2c/8GB  6_PortA8
    ├── XG310  4c/12GB  12_PortA8
    ├── XG310  4c/12GB  10_PortA8
    ├── XG330  4c/12GB  10_PortA8
    ├── XG330  4c/12GB  12_PortA8
    ├── XG430  4c/16GB  A8_B8_C8_M1
    ├── XG430  4c/16GB  10_A8_B8
    ├── XG450  8c/16GB  10_A8_B8
    ├── XG450  8c/16GB  A8_B8_C8_M1
    ├── XG550  24c/24GB  A8_B8_C8_M2
    ├── XG550  32c/24GB  A8_B8_C8_D8_M2
    ├── XG650  40c/48GB  A8_B8_C8_D8_M2
    ├── XG650  40c/48GB  A8_F8_M2
    ├── XG750  48c/32GB  A8_H8_M2
    ├── XG750  48c/64GB  A8_H8_M2
    ├── XGS2180  16c/16GB  Port8_F2MA
    ├── XGS2380  20c/16GB  Port8_F2MA
    ├── XGS3180  20c/32GB  Port8_F2MA
    └── XGS3380  24c/32GB  Port8_F2MA

```
