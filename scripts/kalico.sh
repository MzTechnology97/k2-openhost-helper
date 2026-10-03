#!/usr/bin/env bash
# Kalico for the K2 Pro (MzTechnology97/kalico-k2pro): the K2 extras, the CFS
# Box stack, motor control and PRTouch/z_align all live in this repository.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

install_kalico() {
    step "Kalico K2-OpenHost (${KALICO_BRANCH})"
    if [[ -d "$KLIPPER_DIR" ]] && service_exists klipper; then
        guard_not_printing
    fi
    apt_install git python3-venv python3-dev virtualenv libffi-dev build-essential libncurses-dev
    clone_or_update "$KALICO_REPO" "$KLIPPER_DIR" "$KALICO_BRANCH"
    ok "$KLIPPER_DIR at $(git -C "$KLIPPER_DIR" rev-parse --abbrev-ref HEAD) $(git -C "$KLIPPER_DIR" rev-parse --short HEAD)"

    step "Klippy virtual environment"
    if [[ ! -x "$KLIPPY_ENV/bin/python" ]]; then
        python3 -m venv "$KLIPPY_ENV"
        ok "created $KLIPPY_ENV"
    fi
    "$KLIPPY_ENV/bin/pip" install -q --upgrade pip wheel
    "$KLIPPY_ENV/bin/pip" install -q -r "$KLIPPER_DIR/scripts/klippy-requirements.txt"
    ok "requirements installed ($("$KLIPPY_ENV/bin/python" --version))"
    # The C helper is compiled on first start; build it now so errors show here.
    if "$KLIPPY_ENV/bin/python" -c "import sys; sys.path.insert(0, '$KLIPPER_DIR/klippy'); import chelper; chelper.get_ffi()" >/dev/null 2>&1; then
        ok "C helper built"
    else
        warn "the C helper did not build yet; Klipper retries at start (check klippy.log)"
    fi

    step "Klipper service"
    mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$GCODES_DIR" "$COMMS_DIR" "$SYSTEMD_ENV_DIR"
    render_template "${FILES_DIR}/systemd/klipper.env" "$SYSTEMD_ENV_DIR/klipper.env"
    if [[ -f /etc/systemd/system/klipper.service ]] && ! grep -q "k2-openhost-helper" /etc/systemd/system/klipper.service; then
        sudo cp /etc/systemd/system/klipper.service "/etc/systemd/system/klipper.service.bak-$(date +%Y%m%d-%H%M%S)"
        info "previous klipper.service backed up"
    fi
    sudo_render "${FILES_DIR}/systemd/klipper.service" /etc/systemd/system/klipper.service
    # Wait for the three gadget channels before Klipper starts (external host
    # can boot faster than the T113 bridges).
    sudo "$KLIPPER_DIR/scripts/install-k2-openhost-systemd-gate.sh" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable klipper >/dev/null 2>&1
    ok "klipper.service enabled, waits up to 60 s for ${K2_MAIN_TTY} ${K2_NOZZLE_TTY} ${K2_RS485_TTY}"
    mark_installed kalico
}

update_kalico() {
    step "Updating Kalico"
    guard_not_printing
    clone_or_update "$KALICO_REPO" "$KLIPPER_DIR" "$KALICO_BRANCH"
    "$KLIPPY_ENV/bin/pip" install -q -r "$KLIPPER_DIR/scripts/klippy-requirements.txt"
    restart_service klipper
}

remove_kalico() {
    step "Removing the Klipper service"
    guard_not_printing
    confirm "Stop and remove klipper.service? ($KLIPPER_DIR, $KLIPPY_ENV and your config are kept)" n || return 0
    sudo systemctl disable --now klipper >/dev/null 2>&1 || true
    [[ -x "$KLIPPER_DIR/scripts/install-k2-openhost-systemd-gate.sh" ]] \
        && sudo "$KLIPPER_DIR/scripts/install-k2-openhost-systemd-gate.sh" --remove >/dev/null || true
    sudo rm -f /etc/systemd/system/klipper.service
    sudo systemctl daemon-reload
    mark_removed kalico
    ok "klipper.service removed"
}

case "${1:-install}" in
    install) install_kalico ;;
    update) update_kalico ;;
    remove) remove_kalico ;;
    *) die "usage: $0 install|update|remove" ;;
esac
