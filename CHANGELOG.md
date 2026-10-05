# Changelog

## Unreleased

- **Stable serial names by default.** Main, Nozzle and RS-485 are now addressed as `/dev/serial/by-id/usb-Allwinner_Technology_Inc._Gadget_Serial-if00/01/02-port0`:
  - the Kalico profile's `printer.cfg` uses them (kalico-k2pro#20), and the Klipper start gate waits for the same names;
  - why: with `/dev/ttyUSB0/1/2`, a gadget reconnect while Klipper held the old ports renumbered them to `ttyUSB2/3/4` and `FIRMWARE_RESTART` could not reconnect (K2-OpenHost USB_BRIDGE failure tests);
  - menu 19 (`config serial-names`) now converts an older `printer.cfg` by section, whatever its old values, keeping comments and CRLF; `--udev` selects `/dev/k2-*` instead.
- doctor: flags any other process that uses a K2 gadget channel and the retired Cartographer MUX demux (`k2-openhost-demux`), and shows the RS-485 link state from Klipper. A second reader on the RS-485 channel steals the CFS and motor replies: it happened after a host reboot, with the demux started by hand.
- Host preparation (menu 3) and `scripts/system.sh retire-demux` stop the old demux and move its unit and script to `~/printer_data/backup`.
- T113 menu: new read-only **23) Check the printer** (`./helper.sh t113 check`): K2 Pro model, slot, free space, firmware release and the Creality release slot B would use. The other T113 entries move to 24–31. The README has a Printer T113 bootstrap section, and new terminal screenshots of the menu, help, check and `k2oh-mcu-fw update`.
- The T113 bootstrap moved to its own repository, [k2-openhost-t113-bootstrap](https://github.com/MzTechnology97/k2-openhost-t113-bootstrap) (history kept). The T113 menu clones it to `~/k2-openhost-t113-bootstrap`.
- The T113 bootstrap builds slot B from the release slot A runs, or a newer one, with a warning: it was prepared and tested on stock 1.1.0.94 only. Menu 30 runs `k2oh-mcu-fw update`: latest Creality release, flash only on confirmation.
- **T113 bootstrap (slot B), experimental, not yet run on hardware.** Menu 23–29 / `./helper.sh t113 …`:
  - asks the printer IP and this host's IP;
  - checks over SSH (read-only) that the printer is a K2 Pro (`F012`, `CR0CN200400C10`) on stock 1.1.0.94;
  - builds slot B from Creality's own OTA (downloaded from Creality's CDN, MD5-checked), adds HelixScreen and writes slot B with backups, leaving slot A untouched;
  - trial boot that a power cycle undoes, commit, back to slot A.

  Slot B runs the USB gadget, one bridge per bus, Wi-Fi, a first-boot HelixScreen install pointed at the host, and keeps its writable layer on UDISK. It never formats, checks or wipes UDISK or slot A's `rootfs_data`.
- `t113 link` (menu 32, also offered by the install) connects this host to `k2oh-ctl` on slot B: token to `k2oh_t113.token`, `host` in `k2_t113.cfg`, Moonraker power device `K2_MCU_Power` in `moonraker_k2_t113.conf`, and `[include k2_t113.cfg]` when the installed Kalico has the module. `k2_t113.cfg` joins the K2 profile files.
- `t113 mcu-fw apply|update` (menu 31) stops Klipper on this host only when its print state is a known idle state, then passes `k2oh-mcu-fw` the proof from `k2oh-host-evidence` that the printer's gadget ports are free (MzTechnology97/k2-openhost-t113-bootstrap#1).
- `k2oh-mcu-fw` on slot B:
  - lists and downloads Creality firmware releases;
  - keeps only the MCU/motor/CFS files;
  - flashes them manually with Creality's own tools, after checking that the host Klipper is stopped;
  - with `--cfs`, flashes the CFS through the recovered `cfs_update.json` format, picking the firmware by the exact hardware variant reported by Creality's updater.

- nginx drops the placeholder `X-Api-Key: 88888888` that OrcaSlicer 2.4.2 sends to Moonraker, so its filament Sync and uploads work with trusted LAN clients.
- Cartographer3D now comes from the official plugin (pip package, Moonraker `type: python` updater). The former K2-OpenHost fork is migrated automatically and was retired: the official plugin supports Kalico and the K2 directly.

## 0.1.0 — 2026-10-03 (experimental, pending hardware tests)

- Renamed to K2-OpenHost Installer Helper (repository `k2-openhost-installer-helper`); step-by-step beginner guide in English and Italian with terminal screenshots.

- Menu-driven and unattended (`--yes install full|core`) installer for an external K2-OpenHost host.
- Host preparation: packages, serial groups, udev names for the T113 gadget channels and Cartographer, ModemManager/brltty handling.
- Kalico K2-OpenHost (`kalico-k2pro` `k2-pro-openhost`) with `klipper.service` and the gadget start gate.
- K2 Pro configuration profile from `kalico-k2pro` `config/k2`, never overwriting existing files.
- Moonraker with a LAN `moonraker.conf` and update-manager entries.
- Mainsail K2-OpenHost from prebuilt releases, nginx on port 80.
- Optional: Cartographer3D (K2-OpenHost fork), Shake&Tune, Moonraker timelapse, Crowsnest, host MCU, Spoolman, Mobileraker, OctoEverywhere.
- Maintenance: read-only `doctor`, update, config diff, `/dev/k2-*` serial names, backup/restore.
