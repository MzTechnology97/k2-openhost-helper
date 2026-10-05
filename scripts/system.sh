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

    step "T113 USB gadget serial driver"
    # The T113 uses three configfs gser functions with the standard Linux
    # Gadget Serial VID/PID 0525:a4a6. The generic usbserial driver does not
    # claim arbitrary vendor-specific interfaces unless this pair is supplied.
    # Persist it for every boot/kernel update, then also bind a gadget that is
    # already present now. new_id covers the case where usbserial was loaded
    # earlier without the module parameters; do not unload the driver because
    # that could disrupt unrelated serial devices.
    sudo_render "${FILES_DIR}/modprobe/k2-openhost-gadget-serial.conf" \
        /etc/modprobe.d/k2-openhost-gadget-serial.conf
    sudo_render "${FILES_DIR}/modules-load/k2-openhost-gadget-serial.conf" \
        /etc/modules-load.d/k2-openhost-gadget-serial.conf
    sudo modprobe usbserial vendor=0x0525 product=0xa4a6
    if [[ -e /sys/bus/usb-serial/drivers/generic/new_id ]]; then
        printf '0525 a4a6\n' | sudo tee /sys/bus/usb-serial/drivers/generic/new_id \
            >/dev/null 2>&1 || true
    fi
    sudo udevadm settle || true
    ok "usbserial persists for T113 gadget 0525:a4a6"

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
    step "Removing K2-OpenHost host rules"
    sudo rm -f /etc/udev/rules.d/99-k2-openhost.rules \
        /etc/modprobe.d/k2-openhost-gadget-serial.conf \
        /etc/modules-load.d/k2-openhost-gadget-serial.conf
    # Deliberately do not unload usbserial here: another live serial device or
    # the printer itself may still be using it. The binding disappears on the
    # next reboot once the persistent files above are gone.
    sudo udevadm control --reload-rules
    mark_removed system
    ok "removed (loaded serial drivers, packages, groups and printer_data are kept)"
}

case "${1:-install}" in
    install) install_system ;;
    remove) remove_system ;;
    *) die "usage: $0 install|remove" ;;
esac
