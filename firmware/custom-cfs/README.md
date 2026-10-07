# Custom CFS firmware

I use this directory for the installer manifest of my experimental CFS firmware. Firmware binaries remain outside this repository and are published in the dedicated [k2-cfs-rfid-tools firmware tree](https://github.com/MzTechnology97/k2-cfs-rfid-tools/tree/main/firmware).

## Current candidate: v3.3 / API7 stock capture

The current manifest-approved image is:

```text
filename:
cfs0_050_G32-cfs0_000_153-rfid-stockcapture-v3_3.bin

hardware:
cfs0_050_G32

source application:
cfs0_000_153

size:
176744 bytes

CFS container CRC16:
0x97E9

SHA-256:
5bab3acff49253a54089e779ea473d2cf587db09ab0d9c07c4d6c2e31b810388
```

I **hardware-validated this candidate on my K2 Pro**. It exposes diagnostic API7 and keeps Creality's original RFID task as the RF owner. For Bambu fallback it temporarily substitutes the derived sector-1 Key A at the original stock authentication calls and captures only block 4 material detail plus block 5 RGBA into scratch records.

It does **not** expose tag writes, UID mutation, sector-trailer writes, OTP/lock writes or EEPROM writes, and the API7 Bambu path does not use direct host RF.

During my hardware validation on 2026-10-07 I successfully identified a real Bambu Lab tag as:

```text
UID       233A111D
ATQA      0400
SAK       08
material  PLA
detail    PLA Matte
colour    #FFFFFF
```

I also validated the automatic path:

```text
Creality stock read -> unknown -> API7 Bambu fallback -> Bambulab PLA Matte / #FFFFFF
```

The CFS remains the source of the slot's remaining-filament percentage. API7 v3.3 intentionally does not capture Bambu block 14 and does not write usage back to the tag.

## Get the binary

Download the exact file from:

```text
https://github.com/MzTechnology97/k2-cfs-rfid-tools/tree/main/firmware/v3.3-stockcapture
```

Place it next to this manifest:

```text
firmware/custom-cfs/
├── manifest.json
└── cfs0_050_G32-cfs0_000_153-rfid-stockcapture-v3_3.bin
```

Verify the SHA-256 before flashing.

## Guarded command

From the repository root on the CM5:

```bash
./helper.sh t113 mcu-fw apply --cfs \
  --cfs-image ./firmware/custom-cfs/cfs0_050_G32-cfs0_000_153-rfid-stockcapture-v3_3.bin \
  --cfs-sha256 5bab3acff49253a54089e779ea473d2cf587db09ab0d9c07c4d6c2e31b810388
```

The helper verifies the image on the CM5, checks its hardware/application identity, uploads it to the T113, verifies it again there, stops Klipper only after those checks, and delegates the actual flash to Creality's stock `mcu_update / mcu_util_485` path.

Do not rename the image arbitrarily: the filename is part of the guarded application-identity checks.

### Bootstrap dependency

Use T113 bootstrap 0.1.2 or later. The guarded path validates the CFS container metadata, declared application length, CRC16, initial MSP/reset vector and the targeted update result before considering the operation successful.

## Interactive menu

The installer exposes manifest-approved images under:

```text
[Experimental]
40) Experimental CFS firmware
```

Menu 40 verifies the local binary SHA-256 and target identity, displays the firmware-risk disclaimer, and requires the exact acknowledgement:

```text
FLASH EXPERIMENTAL CFS
```

The acknowledgement is never bypassed by `--yes`.

A binary is not selectable until it is both present locally in this directory and approved by `manifest.json`.