# Changelog

## Unreleased

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
