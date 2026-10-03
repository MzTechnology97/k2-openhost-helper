# K2-OpenHost Helper

> **Experimental — pending hardware tests / Sperimentale — in attesa dei test hardware**
>
> The installer reproduces the software stack validated on the K2-OpenHost reference machine (Creality K2 Pro + Raspberry Pi CM5), but a complete install on a fresh host has not been verified end to end yet. Use a spare SD card or eMMC image and keep your current setup.
>
> L'installer riproduce lo stack validato sulla macchina di riferimento K2-OpenHost (Creality K2 Pro + Raspberry Pi CM5), ma un'installazione completa su un host pulito non è ancora stata verificata dall'inizio alla fine. Usa una SD o un'immagine eMMC di prova e conserva la configurazione attuale.

A menu-driven installer, in the style of the [Creality Helper Script for the K2 series](https://github.com/tofuliang/Creality-Helper-Script-K2-Series), that turns an external Linux host into a ready [K2-OpenHost](https://github.com/MzTechnology97/K2-OpenHost) host: Kalico + Moonraker + Mainsail running the Creality K2 Pro through the original mainboard, with the T113 acting as a USB gadget bridge.

```text
Creality K2 Pro mainboard (T113)                External Linux host (this installer)
  Main MCU   ttyS2 ── ttyGS0 ─┐                  ┌── /dev/ttyUSB0 = /dev/k2-main
  Nozzle MCU ttyS3 ── ttyGS1 ─┼── service USB ───┼── /dev/ttyUSB1 = /dev/k2-nozzle
  RS-485/CFS ttyS5 ── ttyGS2 ─┘                  └── /dev/ttyUSB2 = /dev/k2-rs485
                                                     Kalico · Moonraker · Mainsail
  Cartographer3D (optional) ────────── direct USB ──> /dev/k2-cartographer
```

**English** · [Italiano](#italiano)

## Requirements

- A Debian-based host: Raspberry Pi OS / Debian 12 (bookworm) or newer, Ubuntu, Armbian. Tested target: Raspberry Pi CM5 (aarch64).
- A normal user with `sudo` (not root). Klipper runs as that user.
- Internet access during the install.
- The K2 connected through its service Micro-USB port, with the T113 running the three USB gadget serial bridges. Preparing the T113 is described in [USB gadget transport](https://github.com/MzTechnology97/K2-OpenHost/blob/main/docs/en/USB_GADGET.md); an automatic T113 bootstrap will join this repository after the hardware tests.

## Install

```bash
git clone https://github.com/MzTechnology97/k2-openhost-helper.git ~/k2-openhost-helper
~/k2-openhost-helper/helper.sh
```

Choose **1) Full install** in the menu, or run it unattended:

```bash
~/k2-openhost-helper/helper.sh --yes install full
```

Then open `http://<host-ip>/` and check the host:

```bash
~/k2-openhost-helper/helper.sh doctor
```

Reboot once after the first install if you were added to the `dialout`/`tty` groups.

## What gets installed

| Step                     | What it does                                                                                                                                                                                                                                                                                      |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Host preparation**     | Build tools and Python, `dialout`/`tty` groups, udev names `/dev/k2-main`, `/dev/k2-nozzle`, `/dev/k2-rs485`, `/dev/k2-cartographer`; disables ModemManager and removes brltty (both grab USB serial ports); creates `~/printer_data`.                                                             |
| **Kalico K2-OpenHost**   | [kalico-k2pro](https://github.com/MzTechnology97/kalico-k2pro) `k2-pro-openhost` in `~/klipper` (K2 extras, CFS/Box stack, closed-loop motor control, PRTouch, z_align, power-loss recovery, built-in KAMP), `~/klippy-env`, `klipper.service`, and a start gate that waits up to 60 s for the three gadget channels. |
| **K2 Pro configuration** | The `config/k2` profile from kalico-k2pro into `~/printer_data/config`: `printer.cfg`, `box.cfg`, `macros.cfg`, `start_print.cfg`, `motor_control.cfg`, `prtouch.cfg`, `kamp.cfg`, `timelapse.cfg`, `overrides.cfg`, `cartographer.cfg`. Existing files are kept; the profile version is saved as `<file>.k2oh-new`. |
| **Moonraker**            | Upstream Moonraker with its own installer (virtualenv, service, polkit) and a `moonraker.conf` for a LAN host, with update-manager entries for the Mainsail fork and this helper. Kalico and Moonraker are updated by Moonraker's built-in entries.                                                 |
| **Mainsail K2-OpenHost** | The latest prebuilt [mainsail-k2openhost](https://github.com/MzTechnology97/mainsail-k2openhost) release (CFS panel, live filament path, filament library, print mapping) served by nginx on port 80. Without a release it builds from source when Node.js 20+ is present.                         |
| **Full install** adds    | Moonraker timelapse (the K2 profile ships its macros) and Klippain Shake&Tune.                                                                                                                                                                                                                    |

Optional components: **Cartographer3D** from the dedicated [K2-OpenHost fork](https://github.com/MzTechnology97/cartographer3d-plugin-k2openhost) (direct USB; PRTouch stays the validated probe). Kalico does not ship Cartographer: the fork is installed in `~/klippy-env` with its loader in `klippy/plugins/`, and the helper refreshes that loader after every Kalico install or update. Also optional: **Crowsnest** webcam, **host MCU** `[mcu rpi]`, **Spoolman** connection, **Mobileraker**, **OctoEverywhere**.

KAMP is not installed separately: Kalico already includes it, and the K2 profile's `kamp.cfg` configures it.

## Maintenance

| Command                          | Purpose                                                                                       |
| -------------------------------- | --------------------------------------------------------------------------------------------- |
| `helper.sh doctor`               | Read-only check: groups, ModemManager, gadget channels vs `printer.cfg`, services, Kalico, Mainsail, CFS and filament library. |
| `helper.sh update`               | Update Kalico, Moonraker and Mainsail (refuses while printing).                                |
| `helper.sh config diff`          | Compare your configuration with the K2 profile.                                                |
| `helper.sh config serial-names`  | Switch `printer.cfg` and the start gate to `/dev/k2-*` names, independent of USB enumeration order. |
| `helper.sh backup` / `restore`   | Archive `~/printer_data/config`, the CFS filament library and CFS state in `~/k2-openhost-backups`. |

Moonraker's update manager also keeps Kalico, Moonraker, Mainsail (pre-release channel) and this helper up to date from the web interface.

## Safety

- Nothing is deleted: existing checkouts are moved aside (`<dir>.before-k2openhost-<date>`), files are backed up before changes, and your configuration is never overwritten silently.
- Kalico, Moonraker and Mainsail updates, Klipper restarts and restores refuse to run while a print is running or paused.
- Do not connect or disconnect the gadget cable while printing.

## Roadmap

- End-to-end install test on a fresh Raspberry Pi OS image.
- T113 bootstrap for the original K2 board: disable the unused Creality services, install HelixScreen and start the USB gadget and bridges at every boot.

## Credits

- [K2-OpenHost](https://github.com/MzTechnology97/K2-OpenHost) and its upstream projects: Klipper, Kalico, Jacob10383/Jacobean (K2 Kalico, extras, Cartographer port, Fluidd CFS workflow), luketot (K2 Pro baseline), Moonraker (Arksine), Mainsail, Cartographer3D, Klippain Shake&Tune, moonraker-timelapse, Crowsnest, DnG-Crafts/K2-RFID.
- Menu layout inspired by the Creality Helper Script (Guilouz, sw3defy, tofuliang).

License: GPL-3.0.

---

## Italiano

Un installer a menu, nello stile del [Creality Helper Script per la serie K2](https://github.com/tofuliang/Creality-Helper-Script-K2-Series), che prepara un host Linux esterno per [K2-OpenHost](https://github.com/MzTechnology97/K2-OpenHost): Kalico + Moonraker + Mainsail che comandano la Creality K2 Pro attraverso la scheda madre originale, con il T113 usato come bridge USB gadget.

### Requisiti

- Un host basato su Debian: Raspberry Pi OS / Debian 12 (bookworm) o successivi, Ubuntu, Armbian. Target provato: Raspberry Pi CM5 (aarch64).
- Un utente normale con `sudo` (non root): Klipper gira con quell'utente.
- Connessione a Internet durante l'installazione.
- La K2 collegata dalla porta Micro-USB di servizio, con il T113 che esegue i tre bridge seriali USB gadget. La preparazione del T113 è descritta in [Trasporto USB gadget](https://github.com/MzTechnology97/K2-OpenHost/blob/main/docs/it/USB_GADGET.md); un bootstrap automatico del T113 arriverà in questo repository dopo i test hardware.

### Installazione

```bash
git clone https://github.com/MzTechnology97/k2-openhost-helper.git ~/k2-openhost-helper
~/k2-openhost-helper/helper.sh
```

Scegli **1) Full install** dal menu, oppure senza domande:

```bash
~/k2-openhost-helper/helper.sh --yes install full
```

Poi apri `http://<ip-host>/` e controlla l'host:

```bash
~/k2-openhost-helper/helper.sh doctor
```

Dopo la prima installazione riavvia una volta se l'utente è stato aggiunto ai gruppi `dialout`/`tty`.

### Cosa viene installato

- **Preparazione host**: strumenti di compilazione e Python, gruppi `dialout`/`tty`, nomi udev `/dev/k2-main`, `/dev/k2-nozzle`, `/dev/k2-rs485`, `/dev/k2-cartographer`; disattiva ModemManager e rimuove brltty (entrambi occupano le seriali USB); crea `~/printer_data`.
- **Kalico K2-OpenHost**: [kalico-k2pro](https://github.com/MzTechnology97/kalico-k2pro) `k2-pro-openhost` in `~/klipper` (extras K2, stack CFS/Box, motori closed-loop, PRTouch, z_align, ripresa dopo blackout, KAMP integrato), `~/klippy-env`, `klipper.service` e un'attesa all'avvio che aspetta fino a 60 s i tre canali gadget.
- **Configurazione K2 Pro**: il profilo `config/k2` di kalico-k2pro in `~/printer_data/config`. I file esistenti vengono mantenuti; la versione del profilo viene salvata come `<file>.k2oh-new`.
- **Moonraker**: Moonraker ufficiale con il suo installer e un `moonraker.conf` per la rete locale, con le voci di aggiornamento per il fork Mainsail e per questo helper.
- **Mainsail K2-OpenHost**: l'ultima release precompilata di [mainsail-k2openhost](https://github.com/MzTechnology97/mainsail-k2openhost) (pannello CFS, percorso filamento in tempo reale, libreria filamenti, mappatura in stampa) servita da nginx sulla porta 80.
- **Full install** aggiunge Moonraker timelapse e Klippain Shake&Tune.

Opzionali: **Cartographer3D** dal [fork dedicato K2-OpenHost](https://github.com/MzTechnology97/cartographer3d-plugin-k2openhost) (USB diretta; PRTouch resta la sonda validata). Kalico non include Cartographer: il fork viene installato in `~/klippy-env` con il loader in `klippy/plugins/`, e l'helper lo ripristina dopo ogni installazione o aggiornamento di Kalico. Inoltre: webcam **Crowsnest**, **MCU host** `[mcu rpi]`, collegamento a **Spoolman**, **Mobileraker**, **OctoEverywhere**.

KAMP non viene installato a parte: è già integrato in Kalico e lo configura `kamp.cfg` del profilo K2.

### Manutenzione

- `helper.sh doctor`: controllo in sola lettura di gruppi, ModemManager, canali gadget rispetto a `printer.cfg`, servizi, Kalico, Mainsail, CFS e libreria filamenti.
- `helper.sh update`: aggiorna Kalico, Moonraker e Mainsail (non durante una stampa).
- `helper.sh config diff`: confronta la tua configurazione con il profilo K2.
- `helper.sh config serial-names`: passa `printer.cfg` e l'attesa all'avvio ai nomi `/dev/k2-*`, indipendenti dall'ordine USB.
- `helper.sh backup` / `restore`: archivi di configurazione, libreria filamenti e stato CFS in `~/k2-openhost-backups`.

### Sicurezza

- Nulla viene cancellato: le cartelle esistenti vengono spostate (`<cartella>.before-k2openhost-<data>`), i file vengono copiati prima delle modifiche e la tua configurazione non viene mai sovrascritta senza avviso.
- Aggiornamenti, riavvii di Klipper e ripristini vengono rifiutati durante una stampa in corso o in pausa.

### Roadmap

- Test completo dell'installazione su un'immagine Raspberry Pi OS pulita.
- Bootstrap del T113 sulla scheda K2 originale: disattivazione dei servizi Creality inutili, installazione di HelixScreen e avvio di USB gadget e bridge a ogni accensione.
