#!/usr/bin/env bash
# Host preparation: base packages, serial access, udev names for the T113
# gadget channels, and services that grab USB serial ports.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

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
    *) die "usage: $0 install|remove" ;;
esac
