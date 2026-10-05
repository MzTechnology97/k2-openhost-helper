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

install_health() {
    step "Automatic check after boots and updates"
    sudo_render "${FILES_DIR}/systemd/k2oh-health@.service"         /etc/systemd/system/k2oh-health@.service
    sudo_render "${FILES_DIR}/apt/99k2openhost-health"         /etc/apt/apt.conf.d/99k2openhost-health
    sudo systemctl daemon-reload
    sudo systemctl enable k2oh-health@boot.service >/dev/null 2>&1
    ok "checked at every boot and after apt upgrades; results in the Klipper console and ${LOGS_DIR}/k2oh-health.log"
    info "optional notification: K2OH_HEALTH_NOTIFY_CMD=\"...\" in ${SYSTEMD_ENV_DIR}/k2oh-health.env (gets the summary as \$1)"
}

remove_health() {
    sudo systemctl disable k2oh-health@boot.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/k2oh-health@.service         /etc/apt/apt.conf.d/99k2openhost-health
    sudo systemctl daemon-reload
    ok "automatic check removed"
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
    install_health
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
    remove_health
    mark_removed system
    ok "removed (loaded serial drivers, packages, groups and printer_data are kept)"
}

case "${1:-install}" in
    install) install_system ;;
    remove) remove_system ;;
    retire-demux) retire_legacy_demux ;;
    health-install) install_health ;;
    health-remove) remove_health ;;
    *) die "usage: $0 install|remove|retire-demux|health-install|health-remove" ;;
esac
