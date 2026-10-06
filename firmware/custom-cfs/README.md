# Custom CFS firmware

Place locally generated or experimental CFS firmware images in this directory on the CM5.

Example:

```text
firmware/custom-cfs/
└── cfs0_050_G32-cfs0_000_153-rfid-diag-ro-v2_1.bin
```

The firmware binary itself is intentionally **not tracked by Git**.

For the current K2 CFS RFID v2.1 candidate:

```text
filename:
cfs0_050_G32-cfs0_000_153-rfid-diag-ro-v2_1.bin

SHA-256:
3cf3385dcbc56960c9fe3adcaff516a7d66a0f8ad2b43b5d47d40c341824549c
```

From the repository root on the CM5, the intended command is:

```bash
./helper.sh t113 mcu-fw apply --cfs \
  --cfs-image ./firmware/custom-cfs/cfs0_050_G32-cfs0_000_153-rfid-diag-ro-v2_1.bin \
  --cfs-sha256 3cf3385dcbc56960c9fe3adcaff516a7d66a0f8ad2b43b5d47d40c341824549c
```

The helper verifies the SHA-256 on the CM5, uploads the file to the T113, verifies it again there, stops Klipper only after those checks, and then delegates the actual CFS update to Creality's stock updater.

Do not rename a custom CFS image arbitrarily: the filename is used to validate the expected CFS hardware token and source application generation.

## Interactive menu

The installer exposes these manifest-approved images under:

```text
[Experimental]
40) Experimental CFS firmware
```

The menu reads `manifest.json`, verifies the local binary SHA-256 and the hardware/application identity encoded by its filename, then displays a non-bypassable risk disclaimer before invoking the normal CM5 -> T113 guarded stock-flash path.

A firmware file copied into this directory is **not** selectable from menu 40 until it is also added to `manifest.json` with its expected SHA-256 and exact hardware/application target.