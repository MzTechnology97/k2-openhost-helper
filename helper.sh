#!/usr/bin/env bash
# K2-OpenHost Installer Helper Script
# Prepares an external Linux host (Raspberry Pi CM5/Pi 4/Pi 5 or any
# Debian-based SBC/PC) to run Kalico + Moonraker + Mainsail for a Creality K2
# Pro whose original T113 board acts as the USB gadget bridge.
# https://github.com/MzTechnology97/k2-openhost-installer-helper
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export HELPER_DIR
source "$HELPER_DIR/scripts/lib/common.sh"

S="$HELPER_DIR/scripts"
VERSION="$(cat "$HELPER_DIR/VERSION" 2>/dev/null || echo dev)"

run() { bash "$S/$1" "${@:2}"; }

install_core() {
    run system.sh install
    run kalico.sh install
    run config.sh install
    run moonraker.sh install
    run mainsail.sh install
    step "Starting Klipper"
    # --no-block: the start gate waits up to 60 s for the K2 gadget channels.
    sudo systemctl restart --no-block klipper
    ok "klipper.service starting (it connects once the K2 is attached)"
}

install_full() {
    install_core
    run extras.sh timelapse
    run extras.sh shaketune
    sudo systemctl restart --no-block klipper
}

summary() {
    step "Done"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    info "Mainsail:  http://${ip:-<host-ip>}/"
    info "Check:     $HELPER_DIR/helper.sh doctor"
    info "If you were added to the dialout/tty groups, reboot once before the first print."
    info "Connect the host to the K2 service Micro-USB port with the T113 bridge running;"
    info "Klipper waits up to 60 s for the three gadget channels at every start."
}

header() {
    clear 2>/dev/null || true
    printf '%s======================================================%s\n' "$C_WHITE" "$C_NC"
    printf '%s   K2-OpenHost Installer Helper %s%s\n' "$C_WHITE" "$VERSION" "$C_NC"
    printf '%s   External Linux host for the Creality K2 Pro%s\n' "$C_DIM" "$C_NC"
    printf '%s======================================================%s\n' "$C_WHITE" "$C_NC"
    printf '%s   EXPERIMENTAL - pending hardware tests%s\n' "$C_YELLOW" "$C_NC"
    printf '   %s\n\n' "$(os_summary)"
}

item() { printf '   %s%3s)%s %s%-26s%s %s%s%s\n' "$C_YELLOW" "$1" "$C_NC" "$C_GREEN" "$2" "$C_NC" "$C_DIM" "${3:-}" "$C_NC"; }
mark() { is_installed "$1" && printf '[installed]' || true; }

do_choice() {
    case "$1" in
        1) confirm "Run the full install?" y && { install_full; summary; } ;;
        2) confirm "Run the core install?" y && { install_core; summary; } ;;
        3) run system.sh install ;;
        4) run kalico.sh install ;;
        5) run config.sh install ;;
        6) run moonraker.sh install ;;
        7) run mainsail.sh install ;;
        8) run extras.sh cartographer ;;
        9) run extras.sh shaketune ;;
        10) run extras.sh timelapse ;;
        11) run extras.sh crowsnest ;;
        12) run extras.sh hostmcu ;;
        13) run extras.sh spoolman ;;
        14) run extras.sh mobileraker ;;
        15) run extras.sh octoeverywhere ;;
        16) run doctor.sh || true ;;
        17) run kalico.sh update; run moonraker.sh update; run mainsail.sh update ;;
        18) run config.sh diff | less -R ;;
        19) run config.sh serial-names ;;
        20) run backup.sh backup ;;
        21) run backup.sh restore ;;
        22) guard_not_printing; restart_service klipper; restart_service moonraker ;;
        23) run t113.sh install ;;
        24) run t113.sh status ;;
        25) run t113.sh boot-b ;;
        26) run t113.sh commit ;;
        27) run t113.sh boot-a ;;
        28) run t113.sh host ;;
        29) run t113.sh mcu-fw status ;;
        0|q|Q) exit 0 ;;
        *) warn "invalid choice" ;;
    esac
}

menu() {
    while true; do
        header
        printf '  %s[Install]%s\n' "$C_WHITE" "$C_NC"
        item 1 "Full install" "core + Moonraker timelapse + Shake&Tune (recommended)"
        item 2 "Core install" "host prep, Kalico, K2 Pro config, Moonraker, Mainsail"
        echo
        printf '  %s[Components]%s\n' "$C_WHITE" "$C_NC"
        item 3 "Host preparation" "packages, serial groups, udev names, ModemManager $(mark system)"
        item 4 "Kalico K2-OpenHost" "kalico-k2pro, klippy-env, klipper.service, start gate $(mark kalico)"
        item 5 "K2 Pro configuration" "profile from kalico-k2pro config/k2 $(mark config)"
        item 6 "Moonraker" "with update manager entries $(mark moonraker)"
        item 7 "Mainsail K2-OpenHost" "CFS panel, filament path, library, print mapping $(mark mainsail)"
        echo
        printf '  %s[Optional]%s\n' "$C_WHITE" "$C_NC"
        item 8 "Cartographer3D" "official plugin, direct USB $(mark cartographer)"
        item 9 "Klippain Shake&Tune" "$(mark shaketune)"
        item 10 "Moonraker timelapse" "$(mark timelapse)"
        item 11 "Crowsnest webcam" "$(mark crowsnest)"
        item 12 "Host MCU [mcu rpi]" "host GPIO/ADXL and temperature $(mark hostmcu)"
        item 13 "Spoolman connection" "$(mark spoolman)"
        item 14 "Mobileraker companion" "$(mark mobileraker)"
        item 15 "OctoEverywhere" "$(mark octoeverywhere)"
        echo
        printf '  %s[Maintenance]%s\n' "$C_WHITE" "$C_NC"
        item 16 "Doctor" "read-only health check"
        item 17 "Update Kalico, Moonraker and Mainsail"
        item 18 "Compare config with the K2 profile"
        item 19 "Use /dev/k2-* serial names in printer.cfg"
        item 20 "Backup configuration"
        item 21 "Restore configuration"
        item 22 "Restart Klipper / Moonraker"
        echo
        printf '  %s[Printer T113 - slot B]%s\n' "$C_WHITE" "$C_NC"
        item 23 "Install the T113 bootstrap" "K2-OpenHost system in slot B, HelixScreen; slot A untouched"
        item 24 "T113 status" "running slot, next boot, setup, HelixScreen"
        item 25 "Trial boot slot B" "a power cycle returns to slot A"
        item 26 "Keep slot B" "run once slot B works"
        item 27 "Boot slot A" "the printer's original system"
        item 28 "Change the host address" "used by HelixScreen and k2oh-mcu-fw"
        item 29 "MCU firmware status" "versions on the printer (updates: ./helper.sh t113 mcu-fw)"
        echo
        item 0 "Exit"
        echo
        local choice
        printf '  Choice: '
        read -r choice || exit 0
        do_choice "$choice" || fail "the step did not complete (see the messages above)"
        echo
        printf '  Press Enter to return to the menu...'
        read -r _ || exit 0
    done
}

usage() {
    cat <<EOF
K2-OpenHost Installer Helper ${VERSION}

Usage: ./helper.sh [--yes] [command]

  (no command)        interactive menu
  install full        core + Moonraker timelapse + Shake&Tune
  install core        host prep, Kalico, K2 Pro config, Moonraker, Mainsail
  install <part>      system | kalico | config | moonraker | mainsail |
                      cartographer | shaketune | timelapse | crowsnest |
                      hostmcu | spoolman | mobileraker | octoeverywhere
  update              Kalico, Moonraker and Mainsail
  doctor              read-only health check
  config diff         compare your config with the K2 profile
  backup | restore    configuration backups in ${BACKUP_DIR}
  t113 <command>      printer T113 bootstrap: install | status | boot-b |
                      commit | boot-a | host [IP] | mcu-fw <args>

  --yes               answer yes to every question (unattended install)

Environment overrides: KALICO_BRANCH (default ${KALICO_BRANCH}), PRINTER_DATA,
KLIPPER_DIR, KLIPPY_ENV, MAINSAIL_DIR, MAINSAIL_GH_REPO.
EOF
}

main() {
    if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
        export ASSUME_YES=1
        shift
    fi
    case "${1:-menu}" in
        -h|--help|help) usage; return 0 ;;
    esac
    require_not_root
    require_debian
    case "${1:-menu}" in
        menu) menu ;;
        install)
            require_sudo
            case "${2:-}" in
                full) install_full; summary ;;
                core) install_core; summary ;;
                system|kalico|config|moonraker|mainsail) run "$2.sh" install ;;
                cartographer|shaketune|timelapse|crowsnest|hostmcu|spoolman|mobileraker|octoeverywhere) run extras.sh "$2" ;;
                *) usage; return 2 ;;
            esac ;;
        update) require_sudo; run kalico.sh update; run moonraker.sh update; run mainsail.sh update ;;
        doctor) run doctor.sh ;;
        config) run config.sh "${2:-diff}" "${3:-}" ;;
        backup) run backup.sh backup ;;
        restore) require_sudo; run backup.sh restore ;;
        t113) run t113.sh "${@:2}" ;;
        *) usage; return 2 ;;
    esac
}

main "$@"
