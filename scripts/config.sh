#!/usr/bin/env bash
# K2 Pro configuration profile from kalico-k2pro (config/k2) into
# ~/printer_data/config. Existing files are never overwritten silently.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROFILE_DIR="${KLIPPER_DIR}/config/k2"
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

    step "Serial paths"
    info "printer.cfg uses ${K2_MAIN_TTY} (Main MCU), ${K2_NOZZLE_TTY} (Nozzle MCU) and ${K2_RS485_TTY} (RS-485/CFS),"
    info "the order the T113 gadget enumerates on a host with no other USB serial adapters."
    info "The udev names /dev/k2-main, /dev/k2-nozzle and /dev/k2-rs485 always point to the right channel;"
    info "'$0 serial-names' switches printer.cfg to them."
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

serial_names() {
    local cfg="$CONFIG_DIR/printer.cfg"
    [[ -f "$cfg" ]] || die "$cfg not found"
    step "Switching printer.cfg to the udev names"
    backup_file "$cfg"
    sed -i -E \
        -e "s#^(serial:[[:space:]]*)${K2_MAIN_TTY}\b#\1/dev/k2-main#" \
        -e "s#^(serial:[[:space:]]*)${K2_NOZZLE_TTY}\b#\1/dev/k2-nozzle#" \
        -e "s#^(serial:[[:space:]]*)${K2_RS485_TTY}\b#\1/dev/k2-rs485#" \
        "$cfg"
    # Keep the Klipper start gate in step with the new names.
    local dropin=/etc/systemd/system/klipper.service.d/k2-openhost-transport.conf
    if [[ -f "$dropin" ]]; then
        sudo sed -i 's#^Environment="K2_OPENHOST_TRANSPORT_DEVICES=.*#Environment="K2_OPENHOST_TRANSPORT_DEVICES=/dev/k2-main /dev/k2-nozzle /dev/k2-rs485"#' "$dropin"
        sudo systemctl daemon-reload
    fi
    grep -nE '^serial:' "$cfg" | sed 's/^/    /'
    ok "restart Klipper to apply"
}

case "${1:-install}" in
    install) install_config "${2:-}" ;;
    diff) diff_config ;;
    serial-names) serial_names ;;
    *) die "usage: $0 install [--force]|diff|serial-names" ;;
esac
