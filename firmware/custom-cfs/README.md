# Custom CFS firmware

Place locally generated or experimental CFS firmware images in this directory on the CM5.

The firmware binary itself is intentionally **not tracked by Git**. Only manifest metadata and documentation are committed.

## Current experimental candidate

The previous extended v2.1 candidate is intentionally no longer offered by the installer. Hardware testing showed that its container metadata was inconsistent with the modified image size/content, and the CFS reported `START_APP NACK`.

The current first-test candidate is the minimal same-size v2.2 image:

```text
filename:
cfs0_050_G32-cfs0_000_153-rfid-diag-minimal-samesize-v2_2.bin

source application:
cfs0_000_153

size:
175672 bytes / 0x2AE38

CFS container CRC16:
0xE4D4

SHA-256:
c253f340c5ced05cf3c65e4a454a88797476fe4880396709b0526772fefdb972
```

This candidate is deliberately minimal and passive. It exposes only `INFO` and `STOCK_STATE`; it does not add active RFID polling, authentication, block reads, tag writes, EEPROM writes, or arbitrary RF transceive support.

Example local layout:

```text
firmware/custom-cfs/
├── manifest.json
└── cfs0_050_G32-cfs0_000_153-rfid-diag-minimal-samesize-v2_2.bin
```

From the repository root on the CM5, the intended guarded command is:

```bash
./helper.sh t113 mcu-fw apply --cfs \
  --cfs-image ./firmware/custom-cfs/cfs0_050_G32-cfs0_000_153-rfid-diag-minimal-samesize-v2_2.bin \
  --cfs-sha256 c253f340c5ced05cf3c65e4a454a88797476fe4880396709b0526772fefdb972
```

The helper verifies the SHA-256 on the CM5, uploads the file to the T113, verifies it again there, stops Klipper only after those checks, and then delegates the actual CFS update to Creality's stock updater.

Do not rename a custom CFS image arbitrarily: the filename is used to validate the expected CFS hardware token and source application generation.

### Bootstrap dependency

Before this candidate is considered ready for a hardware test, the T113 bootstrap must include the fail-closed custom-CFS container validation merged in `k2-openhost-t113-bootstrap` commit `4e3ae802b6375ca8f3c903af75cb49e366314f2d`. That validation checks the internal application ID, declared image length, CFS CRC16, initial MSP/reset vector, and requires the targeted CFS update result to be `ok`.

The installer repository still does **not** contain the firmware binary itself. Copy the locally generated and independently validated binary into `firmware/custom-cfs/` before using the menu.

## Interactive menu

The installer exposes manifest-approved images under:

```text
[Experimental]
40) Experimental CFS firmware
```

The menu reads `manifest.json`, verifies the local binary SHA-256 and the hardware/application identity encoded by its filename, then displays a non-bypassable risk disclaimer before invoking the normal CM5 -> T113 guarded stock-flash path.

A firmware file copied into this directory is **not** selectable from menu 40 until it is also added to `manifest.json` with its expected SHA-256 and exact hardware/application target.
