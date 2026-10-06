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

CUSTOM_CFS_DIR="${CUSTOM_CFS_DIR:-$HELPER_DIR/firmware/custom-cfs}"
CUSTOM_CFS_MANIFEST="${CUSTOM_CFS_MANIFEST:-$CUSTOM_CFS_DIR/manifest.json}"

experimental_cfs_menu() {
    local -a candidates=()
    local line choice=1 id filename sha hardware application description image actual ack manifest_rows

    [[ -r "$CUSTOM_CFS_MANIFEST" ]] || die "experimental CFS manifest not found: $CUSTOM_CFS_MANIFEST"
    manifest_rows="$(python3 - "$CUSTOM_CFS_MANIFEST" <<'PYMANIFEST'
import json, os, re, sys
p=sys.argv[1]
try:
    doc=json.load(open(p, encoding='utf-8'))
except Exception as exc:
    raise SystemExit('cannot parse manifest: %s' % exc)
if doc.get('schema') != 1 or not isinstance(doc.get('candidates'), list):
    raise SystemExit('unsupported experimental CFS manifest schema')
hex64=re.compile(r'^[0-9a-f]{64}$')
name_re=re.compile(r'^(?P<hw>cfs[0-9]+_[0-9]+_G[0-9]+)-(?P<app>cfs[0-9]+_[0-9]+_[0-9]+)(?:-[A-Za-z0-9_.-]+)?\.bin$')
for item in doc['candidates']:
    fields=[item.get(k) for k in ('id','filename','sha256','hardware','application','description')]
    if not all(isinstance(x,str) and x for x in fields):
        raise SystemExit('manifest candidate has missing fields')
    if any('\t' in x or '\n' in x for x in fields):
        raise SystemExit('manifest fields may not contain tabs/newlines')
    if not hex64.fullmatch(item['sha256'].lower()):
        raise SystemExit('manifest candidate has invalid SHA-256')
    if os.path.basename(item['filename']) != item['filename']:
        raise SystemExit('manifest candidate filename must be a basename')
    m=name_re.fullmatch(item['filename'])
    if not m:
        raise SystemExit('manifest candidate filename does not encode a CFS boot/app identity')
    if m.group('hw') != item['hardware'] or m.group('app') != item['application']:
        raise SystemExit('manifest hardware/application does not match filename')
    print('\t'.join(fields))
PYMANIFEST
    )" || die "cannot load experimental CFS manifest"
    if [[ -n "$manifest_rows" ]]; then
        mapfile -t candidates <<< "$manifest_rows"
    fi
    (( ${#candidates[@]} > 0 )) || die "experimental CFS manifest contains no candidates"

    step "Experimental CFS firmware"
    printf '    %sWARNING:%s these images are experimental and are not stock Creality firmware.\n' "$C_RED" "$C_NC"
    printf '    The normal MCU firmware updater remains available as menu item 31.\n\n'
    local n=1
    for line in "${candidates[@]}"; do
        IFS=$'\t' read -r id filename sha hardware application description <<< "$line"
        image="$CUSTOM_CFS_DIR/$filename"
        if [[ -f "$image" ]]; then
            printf '    %d) %s%s%s\n' "$n" "$C_YELLOW" "$description" "$C_NC"
        else
            printf '    %d) %s [file missing]\n' "$n" "$description"
        fi
        printf '       %s\n' "$filename"
        n=$((n + 1))
    done
    echo

    if (( ${#candidates[@]} > 1 )); then
        printf '    Candidate [1-%d, Enter=cancel]: ' "${#candidates[@]}"
        read -r choice || choice=""
        [[ -n "$choice" ]] || { info "Cancelled."; return 0; }
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )) \
            || die "invalid experimental CFS candidate"
    fi

    line="${candidates[$((choice - 1))]}"
    IFS=$'\t' read -r id filename sha hardware application description <<< "$line"
    image="$CUSTOM_CFS_DIR/$filename"
    [[ -f "$image" ]] || die "firmware file is missing: $image"
    actual="$(sha256sum "$image" | awk '{print $1}')"
    [[ "$actual" == "$sha" ]] || die "experimental CFS SHA-256 mismatch: expected $sha, got $actual"

    cat <<EOF

${C_RED}================ EXPERIMENTAL FIRMWARE DISCLAIMER ================${C_NC}

This operation will replace the application firmware of the CFS with an
experimental, modified image. It is intended only for controlled development
and interoperability testing.

Risks include loss of CFS communication, failed boot, loss of normal filament
or RFID functions, and the need to restore the original Creality CFS firmware.
An interrupted update may require recovery through the stock Creality updater.

The image will be accepted only for the identity encoded by this candidate:
  Hardware / boot token : $hardware
  Source application    : $application
  File                  : $filename
  SHA-256               : $sha

The actual erase/program/start operations are still performed by Creality's
stock mcu_update / mcu_util_485 path on the T113.

Before using this option you should have the original CFS firmware available
for rollback and the printer must be completely idle.

This experimental operation is NOT covered by --yes / unattended mode.
${C_RED}==================================================================${C_NC}

EOF
    printf '    To continue, type exactly: %sFLASH EXPERIMENTAL CFS%s\n    > ' "$C_YELLOW" "$C_NC"
    read -r ack || ack=""
    if [[ "$ack" != "FLASH EXPERIMENTAL CFS" ]]; then
        warn "Experimental CFS flash cancelled."
        return 0
    fi

    run t113.sh mcu-fw apply --cfs --cfs-image "$image" --cfs-sha256 "$sha"
}

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
        23) run t113.sh check ;;
        24) run t113.sh install ;;
        25) run t113.sh status ;;
        26) run t113.sh boot-b ;;
        27) run t113.sh commit ;;
        28) run t113.sh boot-a ;;
        29) run t113.sh host ;;
        30) run t113.sh mcu-fw status ;;
        31) run t113.sh mcu-fw update ;;
        32) run t113.sh link ;;
        40) experimental_cfs_menu ;;
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
        item 19 "Stable serial names in printer.cfg (/dev/k2-*)"
        item 20 "Backup configuration"
        item 21 "Restore configuration"
        item 22 "Restart Klipper / Moonraker"
        echo
        printf '  %s[Printer T113 - slot B]%s\n' "$C_WHITE" "$C_NC"
        item 23 "Check the printer" "read-only: K2 Pro model, slot, firmware release"
        item 24 "Install the T113 bootstrap" "K2-OpenHost system in slot B, HelixScreen; slot A untouched"
        item 25 "T113 status" "running slot, next boot, setup, HelixScreen"
        item 26 "Trial boot slot B" "a power cycle returns to slot A"
        item 27 "Keep slot B" "run once slot B works"
        item 28 "Boot slot A" "the printer's original system"
        item 29 "Change the host address" "used by HelixScreen and k2oh-mcu-fw"
        item 30 "MCU firmware status" "board versions on the printer"
        item 31 "Update MCU firmware" "latest Creality release; flashes only if you confirm"
        item 32 "Link the T113 controls" "buzzer, MCU power rail, telemetry (k2oh-ctl)"
        echo
        printf '  %s[Experimental]%s\n' "$C_YELLOW" "$C_NC"
        item 40 "Experimental CFS firmware" "custom CFS image; explicit risk disclaimer required"
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
  t113 <command>      printer T113 bootstrap: check | install | status | boot-b |
                      commit | boot-a | host [IP] | mcu-fw <args> | link
  experimental-cfs    select a manifest-approved experimental CFS image;
                      always requires the explicit risk acknowledgement phrase

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
        experimental-cfs) experimental_cfs_menu ;;
        *) usage; return 2 ;;
    esac
}

if [[ "${K2OH_HELPER_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"