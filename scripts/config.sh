#!/usr/bin/env bash
# K2 Pro configuration profile from kalico-k2pro (config/k2) into
# ~/printer_data/config. Existing files are never overwritten silently.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROFILE_DIR="${KLIPPER_DIR}/config/k2"
if [[ -d "$PROFILE_DIR/macros" ]]; then
    # printer.cfg keeps the hardware; the printer files live in macros/.
    PROFILE_FILES=(
        printer.cfg
        timelapse.cfg
        macros/system.cfg
        macros/sensors.cfg
        macros/leds.cfg
        macros/print.cfg
        macros/kamp.cfg
        macros/fans.cfg
        macros/maintenance.cfg
        macros/openhost_controls.cfg
        macros/box.cfg
        macros/box_rfid_diag.cfg
        macros/box_rfid_bambu.cfg
        macros/box_rfid_mifare.cfg
        macros/motor_control.cfg
        macros/k2_t113.cfg
        macros/prtouch.cfg
        macros/cartographer.cfg
        macros/overrides.cfg
    )
else
    # Kalico before kalico-k2pro #40: everything in the config root.
    PROFILE_FILES=(
        printer.cfg
        box.cfg
        macros.cfg
        start_print.cfg
        motor_control.cfg
        k2_t113.cfg
        prtouch.cfg
        kamp.cfg
        timelapse.cfg
        overrides.cfg
        cartographer.cfg
    )
fi

require_profile() {
    [[ -d "$PROFILE_DIR" ]] || die "$PROFILE_DIR not found: install Kalico first."
}

install_config() {
    local force="${1:-}"
    require_profile
    step "K2 Pro configuration (kalico-k2pro config/k2)"
    mkdir -p "$CONFIG_DIR"
    local file target pending=()
    for file in "${PROFILE_FILES[@]}"; do
        [[ -f "$PROFILE_DIR/$file" ]] || { warn "$file is not in the profile, skipped"; continue; }
        target="$CONFIG_DIR/$file"
        mkdir -p "$(dirname "$target")"
        if [[ ! -e "$target" ]]; then
            cp "$PROFILE_DIR/$file" "$target"
            ok "$file"
        elif cmp -s <(tr -d '\r' < "$PROFILE_DIR/$file") <(tr -d '\r' < "$target"); then
            ok "$file (already up to date)"
        elif [[ "$force" == "--force" ]]; then
            backup_file "$target"
            cp "$PROFILE_DIR/$file" "$target"
            ok "$file (replaced)"
        else
            cp "$PROFILE_DIR/$file" "$target.k2oh-new"
            pending+=("$file")
        fi
    done
    if (( ${#pending[@]} )); then
        warn "kept your version of: ${pending[*]}"
        info "the profile version was saved next to each one as <file>.k2oh-new; compare with: $0 diff"
    fi
    if [[ -d "$PROFILE_DIR/macros" && "$(printer_file print.cfg)" == "print.cfg" ]]; then
        warn "your printer.cfg still includes printer files from the config root;"
        warn "the profile keeps them in macros/ (printer.cfg.k2oh-new shows the includes)."
        info "Move them into macros/ and update the [include] lines, or install the profile with --force."
    fi

    step "Serial paths"
    if [[ " ${pending[*]} " != *" printer.cfg "* && -f "$CONFIG_DIR/printer.cfg" ]]; then
        set_serial_lines "$CONFIG_DIR/printer.cfg" "$K2_MAIN_TTY" "$K2_NOZZLE_TTY" "$K2_RS485_TTY"
    fi
    info "printer.cfg names the T113 gadget channels by interface: ${K2_MAIN_TTY} (Main MCU),"
    info "${K2_NOZZLE_TTY} (Nozzle MCU), ${K2_RS485_TTY} (RS-485/CFS). They stay right when"
    info "the gadget reconnects and are the same in T113 slot A and slot B."
    info "An older printer.cfg (/dev/ttyUSB0/1/2 or by-id names): '$0 serial-names' converts it."
    mark_installed config
}

diff_config() {
    require_profile
    local file target any=0
    for file in "${PROFILE_FILES[@]}"; do
        target="$CONFIG_DIR/$file"
        [[ -f "$target" && -f "$PROFILE_DIR/$file" ]] || continue
        if ! cmp -s <(tr -d '\r' < "$PROFILE_DIR/$file") <(tr -d '\r' < "$target"); then
            any=1
            printf '\n%s--- profile/%s  +++ yours%s\n' "$C_WHITE" "$file" "$C_NC"
            diff -u <(tr -d '\r' < "$PROFILE_DIR/$file") <(tr -d '\r' < "$target") | tail -n +3 || true
        fi
    done
    (( any )) || ok "your configuration matches the profile"
}

# Set the serial line of [mcu], [mcu nozzle_mcu] and [serial_485 ...] by
# section, whatever value they had; a trailing comment is kept.
set_serial_lines() {
    local cfg="$1" main="$2" nozzle="$3" rs485="$4"
    awk -v main="$main" -v noz="$nozzle" -v rs="$rs485" '
        { cr = ""; if (sub(/\r$/, "")) cr = "\r" }  # keep CRLF files CRLF
        /^\[/ { sec = $0; sub(/[[:space:]]+$/, "", sec) }
        /^serial:/ {
            target = ""
            if (sec == "[mcu]") target = main
            else if (sec == "[mcu nozzle_mcu]") target = noz
            else if (sec ~ /^\[serial_485/) target = rs
            if (target != "") {
                rest = $0
                sub(/^serial:[[:space:]]*[^[:space:]#]*/, "", rest)
                print "serial: " target rest cr
                next
            }
        }
        { print $0 cr }
    ' "$cfg" > "$cfg.k2oh-tmp" && mv "$cfg.k2oh-tmp" "$cfg"
}

# Keep the Klipper start gate waiting for the same names printer.cfg uses.
set_gate_devices() {
    local dropin="${K2OH_GATE_DROPIN:-/etc/systemd/system/klipper.service.d/k2-openhost-transport.conf}"
    [[ -f "$dropin" ]] || return 0
    sudo sed -i "s#^Environment=\"K2_OPENHOST_TRANSPORT_DEVICES=.*#Environment=\"K2_OPENHOST_TRANSPORT_DEVICES=$1 $2 $3\"#" "$dropin"
    sudo systemctl daemon-reload
}

serial_names() {
    local cfg="$CONFIG_DIR/printer.cfg" main nozzle rs485
    [[ -f "$cfg" ]] || die "$cfg not found"
    case "${1:-}" in
        --by-id)
            # Slot A's stock gadget only: slot B's gadget has other by-id names.
            main="${K2_BY_ID}-if00-port0" nozzle="${K2_BY_ID}-if01-port0" rs485="${K2_BY_ID}-if02-port0"
            step "Switching printer.cfg to slot A's by-id names"
            ;;
        ""|--udev)
            main="$K2_MAIN_TTY" nozzle="$K2_NOZZLE_TTY" rs485="$K2_RS485_TTY"
            step "Switching printer.cfg to ${main}, ${nozzle}, ${rs485}"
            [[ "$main" != /dev/k2-* || -f /etc/udev/rules.d/99-k2-openhost.rules ]]                 || warn "the udev rule is not installed yet: run host preparation (menu 3) first"
            ;;
        *) die "usage: $0 serial-names [--by-id]" ;;
    esac
    backup_file "$cfg"
    set_serial_lines "$cfg" "$main" "$nozzle" "$rs485"
    set_gate_devices "$main" "$nozzle" "$rs485"
    grep -nE '^serial:' "$cfg" | sed 's/^/    /'
    ok "restart Klipper to apply"
}

case "${1:-install}" in
    install) install_config "${2:-}" ;;
    diff) diff_config ;;
    serial-names) serial_names "${2:-}" ;;
    *) die "usage: $0 install [--force]|diff|serial-names [--by-id]" ;;
esac
