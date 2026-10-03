#!/usr/bin/env bash
# Moonraker (upstream Arksine/moonraker) with a moonraker.conf for the
# K2-OpenHost host: Mainsail fork updates, helper updates, trusted LAN.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

install_moonraker() {
    step "Moonraker"
    clone_or_update "$MOONRAKER_REPO" "$MOONRAKER_DIR"

    step "moonraker.conf"
    mkdir -p "$CONFIG_DIR"
    local conf
    conf="$(moonraker_conf)"
    if [[ -f "$conf" ]]; then
        ok "keeping the existing $(basename "$conf"); adding missing K2-OpenHost sections"
        backup_file "$conf"
    else
        render_template "${FILES_DIR}/moonraker/moonraker.conf" "$conf"
        ok "created $conf"
    fi
    add_section "$conf" "update_manager mainsail" <<EOF
type: web
channel: beta
repo: ${MAINSAIL_GH_REPO}
path: ${MAINSAIL_DIR}
EOF
    add_section "$conf" "update_manager k2-openhost-installer-helper" <<EOF
type: git_repo
path: ${HELPER_DIR}
origin: https://github.com/MzTechnology97/k2-openhost-installer-helper.git
primary_branch: main
is_system_service: False
EOF

    step "Moonraker environment and service"
    # Upstream installer: packages, virtualenv, moonraker.service, polkit rules.
    "$MOONRAKER_DIR/scripts/install-moonraker.sh" -d "$PRINTER_DATA" -s
    ok "moonraker.service installed"

    # Services Moonraker may restart from the UI and the update manager.
    local asvc="$PRINTER_DATA/moonraker.asvc" name
    touch "$asvc"
    for name in klipper moonraker klipper_mcu crowsnest; do
        grep -qx "$name" "$asvc" || echo "$name" >> "$asvc"
    done
    mark_installed moonraker
}

update_moonraker() {
    step "Updating Moonraker"
    clone_or_update "$MOONRAKER_REPO" "$MOONRAKER_DIR"
    "$MOONRAKER_ENV/bin/pip" install -q -r "$MOONRAKER_DIR/scripts/moonraker-requirements.txt"
    restart_service moonraker
}

remove_moonraker() {
    step "Removing the Moonraker service"
    confirm "Stop and remove moonraker.service? ($MOONRAKER_DIR and moonraker.conf are kept)" n || return 0
    sudo systemctl disable --now moonraker >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/moonraker.service
    sudo systemctl daemon-reload
    mark_removed moonraker
    ok "moonraker.service removed"
}

case "${1:-install}" in
    install) install_moonraker ;;
    update) update_moonraker ;;
    remove) remove_moonraker ;;
    *) die "usage: $0 install|update|remove" ;;
esac
