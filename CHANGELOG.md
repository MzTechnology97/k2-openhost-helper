# Changelog

## Unreleased

- **T113 time zone from the host.** The T113 ships on China time (`Asia/Shanghai`, `CST-8`), so the printer's logs did not line up with the host's. `t113 timezone` sets slot B to this host's zone through `uci` (IANA name and POSIX string from the host's zoneinfo, applied with `/etc/init.d/system reload`, kept in slot B's persistent layer); `boot-b`, `commit` and `update` do it too. Slot A is never written; an unreadable host zone only warns. Tests: `tests/test_t113_timezone.sh`.
- **Config: RFID extras.** `config` also installs `macros/box_rfid_diag.cfg`, `macros/box_rfid_bambu.cfg` and `macros/box_rfid_mifare.cfg` (kalico-k2pro #44). The generic `printer.cfg` keeps their includes commented out: they need the API7 CFS RFID firmware. Without the files, a printer that enables the includes would not start.
- **Automatic check after boots and updates.** `k2oh-health@boot.service` and an apt hook (`k2oh-health@apt.service`) run the doctor and report in the Klipper console, in `printer_data/logs/k2oh-health.log`, and optionally through `K2OH_HEALTH_NOTIFY_CMD`.
  - After apt it also flags a pending reboot, and fails when the newest kernel has no `usbserial`.
  - Installed by `scripts/system.sh install` (menu 3) or `health-install`; `./helper.sh health` runs it by hand.
- The doctor also checks the persistent usbserial binding, the CFS units online and the closed-loop motor startup.
- **Update check at start, like KIAUH.** The helper fetches the branch it follows (10 s timeout), lists the new commits and asks before updating (`git merge --ff-only`), then restarts with the same arguments. It is skipped without a terminal, with `K2OH_NO_UPDATE_CHECK=1`, outside a git checkout, on a detached HEAD or without upstream; `--yes` only reports it; local changes are never touched. Tests: `tests/test_helper_self_update.sh`.
- **Config: printer files in `macros/`.** With kalico-k2pro #40, `config` installs `printer.cfg` plus the printer files in `~/printer_data/config/macros/` (system, sensors, LEDs, print flow, KAMP, fans, maintenance and the modules). `printer_file` finds where a printer keeps a file: `t113 link` and `extras cartographer` write and include `k2_t113.cfg` / `cartographer.cfg` there. Printers that still include the files from the config root keep working and get a warning; an older Kalico installs the root layout as before. Tests: `tests/test_config_layout.sh`.

- **T113: `t113 update [--revert]` (menu 33).** Updates K2-OpenHost's programs and boot links on a running slot B without reinstalling (T113 bootstrap 0.1.3, `update-slot-b.sh`). A reinstall goes through slot A, which flashes its own firmware files back onto the boards at boot. The helper packs the programs, uploads them with SHA-256 checks, shows the printer's `--check`, applies only on confirmation (no question when there is nothing to update) and offers a reboot when boot-time programs changed. Refused on slot A and during a print. Tests: `tests/test_t113_update.sh`.
- `guard_idle` is shared by the slot switch and the update; `upload` takes a destination.

- **Experimental CFS v3.3 / API7 stock capture.** Menu 40 now approves `cfs0_050_G32-cfs0_000_153-rfid-stockcapture-v3_3.bin` (SHA-256 `5bab3acff49253a54089e779ea473d2cf587db09ab0d9c07c4d6c2e31b810388`). It has been validated on the reference K2 Pro with a real Bambu Lab PLA Matte tag and the automatic Creality-unknown → Bambu fallback. The binary itself is published in `MzTechnology97/k2-cfs-rfid-tools/firmware/v3.3-stockcapture/`; the installer keeps only its approval metadata. The earlier v2.1 candidate remains obsolete. Custom images need bootstrap 0.1.2 or later.

- **T113, fixes from the first slot B install on a printer (2026-10-06):**
  - `t113 boot-b` and `boot-a` really reboot the printer. The reboot ran in the background of the SSH session and died with it, then the helper saw SSH still open and reported "the printer came back on slot A" although the T113 never rebooted. The reboot now runs in the foreground, and the printer counts as back only when it answers with a new boot id (`/proc/sys/kernel/random/boot_id`).
  - `boot-b` and `boot-a` refuse while a print is running or paused (they reboot the T113 and cut the MCUs).
  - **Serial names `/dev/k2-main`, `/dev/k2-nozzle`, `/dev/k2-rs485` by default** instead of the by-id names: slot B's gadget has other by-id names (`usb-Creality_K2_Pro_K2-OpenHost_Gadget_Serial_<serial>-…`) than slot A's stock gadget, and Klipper could not find the MCUs. The udev names match vendor, product and interface and are the same in both slots. `t113 install` installs the udev rule when it is missing and converts `printer.cfg` and the start gate; `config serial-names` now selects the udev names and `--by-id` slot A's by-id names. `config install` writes the default names in a newly copied `printer.cfg`.
  - doctor recognises both gadgets and warns about by-id names in `printer.cfg`.
  - SSH to the printer uses keepalives (`ServerAliveInterval`), so a session to a rebooting printer ends.

- Menu 40 `[Experimental]`: adds manifest-approved custom CFS firmware selection with local SHA/identity checks and a non-bypassable `FLASH EXPERIMENTAL CFS` disclaimer before using the guarded stock Creality flash path.

- CM5 helper: `t113 mcu-fw apply --cfs --cfs-image ... --cfs-sha256 ...` now verifies a local custom CFS image, uploads and re-verifies it on the T113, stops Klipper only after those checks, then delegates the actual write to the stock Creality updater and removes the transfer copy.

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