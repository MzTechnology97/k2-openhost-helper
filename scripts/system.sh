#!/usr/bin/env bash
# Host preparation: base packages, serial access, udev names for the T113
# gadget channels, and services that grab USB serial ports.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Left by the retired Cartographer MUX experiment. The demux opened the RS-485
# gadget channel (/dev/ttyUSB2) next to Klipper and stole the CFS and motor
# replies. Cartographer now uses direct USB on the host.
LEGACY_DEMUX_UNIT="k2-openhost-demux.service"
LEGACY_DEMUX_FILES=(/usr/local/libexec/k2-openhost/demux.py)

retire_legacy_demux() {
    local file unit_file found=() backup
    unit_file="$(systemctl show -P FragmentPath "$LEGACY_DEMUX_UNIT" 2>/dev/null || true)"
    [[ -n "$unit_file" && -f "$unit_file" ]] && found+=("$unit_file")
    for file in "${LEGACY_DEMUX_FILES[@]}"; do
        [[ -e "$file" ]] && found+=("$file")
    done
    if (( ${#found[@]} == 0 )); then
        ok "no Cartographer MUX demux left on this host"
        return 0
    fi
    warn "the retired Cartographer MUX demux is still here: ${found[*]}"
    info "it reads the RS-485 channel next to Klipper and steals the CFS and motor replies"
    confirm "Stop it and move its files to $PRINTER_DATA/backup?" y || return 0
    backup="$PRINTER_DATA/backup/legacy-demux-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    sudo systemctl disable --now "$LEGACY_DEMUX_UNIT" >/dev/null 2>&1 || true
    for file in "${found[@]}"; do
        sudo mv "$file" "$backup/"
    done
    sudo chown -R "$(id -un):" "$backup"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$LEGACY_DEMUX_UNIT" >/dev/null 2>&1 || true
    ok "demux stopped and removed; its files are in $backup"
    systemctl is-active --quiet klipper 2>/dev/null \
        && info "restart Klipper when it is idle so it reconnects the RS-485 channel"
    return 0
}

install_system() {
    step "Preparing the host ($(os_summary))"
    apt_install git curl unzip ca-certificates python3 python3-venv python3-dev \
        virtualenv libffi-dev build-essential libncurses-dev pkg-config \
        libusb-1.0-0 usbutils

    step "Serial port access"
    local group
    for group in dialout tty; do
        if id -nG "$(id -un)" | tr ' ' '\n' | grep -qx "$group"; then
            ok "$(id -un) is in $group"
        else
            sudo usermod -aG "$group" "$(id -un)"
            ok "added $(id -un) to $group (takes effect after a new login or reboot)"
        fi
    done

    step "Services that open USB serial ports"
    # ModemManager probes new ttyUSB devices and brltty claims some USB serial
    # adapters; either one can corrupt the MCU sessions on the gadget channels.
    if service_exists ModemManager || systemctl is-active --quiet ModemManager 2>/dev/null; then
        # A masked unit can still be running until it is stopped.
        if systemctl is-active --quiet ModemManager 2>/dev/null             || [[ "$(systemctl is-enabled ModemManager 2>/dev/null || true)" != "masked" ]]; then
            if confirm "Stop and disable ModemManager (it probes serial ports)?" y; then
                sudo systemctl stop ModemManager >/dev/null 2>&1 || true
                sudo systemctl disable ModemManager >/dev/null 2>&1 || true
                sudo systemctl mask ModemManager >/dev/null 2>&1 || true
                ok "ModemManager stopped and masked"
            fi
        else
            ok "ModemManager masked and stopped"
        fi
    fi
    retire_legacy_demux
    if dpkg -s brltty >/dev/null 2>&1; then
        if confirm "Remove brltty (it claims USB serial devices)?" y; then
            sudo apt-get remove -y -qq brltty
            ok "brltty removed"
        fi
    fi

    step "udev names for the K2 serial channels"
    sudo_render "${FILES_DIR}/udev/99-k2-openhost.rules" /etc/udev/rules.d/99-k2-openhost.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=tty || true
    ok "/dev/k2-main, /dev/k2-nozzle, /dev/k2-rs485 and /dev/k2-cartographer are created when the devices appear"

    step "printer_data layout"
    mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$GCODES_DIR" "$COMMS_DIR" "$SYSTEMD_ENV_DIR" "$PRINTER_DATA/certs" "$PRINTER_DATA/backup"
    ok "$PRINTER_DATA"
    mark_installed system
}

remove_system() {
    step "Removing K2-OpenHost udev rules"
    sudo rm -f /etc/udev/rules.d/99-k2-openhost.rules
    sudo udevadm control --reload-rules
    mark_removed system
    ok "removed (packages, groups and printer_data are kept)"
}

case "${1:-install}" in
    install) install_system ;;
    remove) remove_system ;;
    retire-demux) retire_legacy_demux ;;
    *) die "usage: $0 install|remove|retire-demux" ;;
esac
