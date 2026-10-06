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

**Status: withdrawn from the menu (2026-10-06).** It was flashed on the reference printer with T113 bootstrap 0.1.1, and the CFS loader refused to start it (`get start_app NACK`, update `fail`). Bootstrap 0.1.1 named the staged copy after its SHA-256, so `mcu_util_485` wrote `3cf3385dcbc5` as the application version. Bootstrap 0.1.2 keeps the stock name, but the image itself is being revised, so it is no longer in `manifest.json`. The CFS was recovered with the stock 153 through a normal `mcu_update`.

A CFS left in its loader after a failed custom image can be flashed back. If it reports an empty or different application version, `k2oh-mcu-fw apply --cfs` flashes the stock file. If it still reports the stock version, use the custom-image path with the stock file itself (renamed `cfs0_050_G32-cfs0_000_153-stock.bin`, with its SHA-256), which goes through the `CFS=1` pass.

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