#!/usr/bin/env bash
# Optional components for the K2-OpenHost host.
#   hostmcu       Klipper Linux host MCU ([mcu rpi]: host GPIO/ADXL, CM5 temperature)
#   cartographer  Cartographer3D plugin, official (direct USB to the host)
#   shaketune     Klippain Shake&Tune resonance tools
#   timelapse     Moonraker timelapse (the K2 profile ships its macros)
#   crowsnest     webcam streaming
#   spoolman      connect Moonraker to an existing Spoolman server
#   mobileraker   Mobileraker companion (push notifications)
#   octoeverywhere OctoEverywhere remote access
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# add_include <file.cfg>: include it from printer.cfg, before overrides.cfg and
# the SAVE_CONFIG block, unless it is already included.
add_include() {
    local name="$1" cfg="$CONFIG_DIR/printer.cfg"
    [[ -f "$cfg" ]] || { warn "printer.cfg not found; add [include $name] yourself"; return 0; }
    if grep -Eq "^\[include[[:space:]]+(\./)?${name//./\\.}\]" "$cfg"; then
        ok "printer.cfg already includes $name"
        return 0
    fi
    backup_file "$cfg"
    if grep -Eq "^#[[:space:]]*\[include[[:space:]]+(\./)?${name//./\\.}\]" "$cfg"; then
        sed -i -E "s#^\#[[:space:]]*\[include[[:space:]]+(\./)?${name//./\\.}\]#[include ${name}]#" "$cfg"
    else
        python3 - "$cfg" "$name" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
line = "[include %s]" % name
index = len(lines)
for i, text in enumerate(lines):
    if text.startswith("#*# <") or text.strip().startswith(
            ("[include overrides.cfg]", "[include macros/overrides.cfg]")):
        index = i
        break
lines.insert(index, line)
open(path, "w").write("\n".join(lines))
PY
    fi
    ok "printer.cfg includes $name"
}

hostmcu() {
    step "Klipper Linux host MCU"
    [[ -d "$KLIPPER_DIR" ]] || die "install Kalico first"
    guard_not_printing
    [[ -f "$KLIPPER_DIR/.config" ]] && cp "$KLIPPER_DIR/.config" "$KLIPPER_DIR/.config.before-hostmcu"
    printf 'CONFIG_LOW_LEVEL_OPTIONS=y\nCONFIG_MACH_LINUX=y\n' > "$KLIPPER_DIR/.config"
    make -C "$KLIPPER_DIR" olddefconfig >/dev/null
    make -C "$KLIPPER_DIR" clean >/dev/null
    make -C "$KLIPPER_DIR" -j"$(nproc)" >/dev/null
    sudo "$KLIPPER_DIR/scripts/flash-linux.sh" "$KLIPPER_DIR/out" >/dev/null
    sudo install -m 644 "$KLIPPER_DIR/scripts/klipper-mcu.service" /etc/systemd/system/klipper-mcu.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now klipper-mcu >/dev/null 2>&1
    ok "klipper_mcu running on /tmp/klipper_host_mcu"
    local cfg="$CONFIG_DIR/printer.cfg"
    if [[ -f "$cfg" ]] && grep -Eq '^#[[:space:]]*\[mcu rpi\]' "$cfg"; then
        if confirm "Enable [mcu rpi] in printer.cfg?" y; then
            backup_file "$cfg"
            sed -i -E 's/^#[[:space:]]*\[mcu rpi\]/[mcu rpi]/; s#^\#[[:space:]]*(serial:[[:space:]]*/tmp/klipper_host_mcu)#\1#' "$cfg"
            ok "[mcu rpi] enabled"
        fi
    fi
    mark_installed hostmcu
}

cartographer() {
    step "Cartographer3D plugin (official)"
    [[ -x "$KLIPPY_ENV/bin/python" ]] || die "install Kalico first"
    # Kalico does not ship Cartographer; the official plugin supports Kalico
    # and the K2 (non-critical reconnect, register_as_probe) directly.
    local conf
    conf="$(moonraker_conf)"
    if [[ -d "$LEGACY_CARTOGRAPHER_DIR" ]]; then
        info "replacing the former K2-OpenHost Cartographer fork"
        "$KLIPPY_ENV/bin/pip" uninstall -q -y cartographer3d-plugin || true
        mkdir -p "$BACKUP_DIR"
        mv "$LEGACY_CARTOGRAPHER_DIR" "$BACKUP_DIR/cartographer3d-plugin-k2openhost-$(date +%Y%m%d-%H%M%S)"
        ok "old fork moved to $BACKUP_DIR"
    fi
    # Moonraker updates the official plugin as a pip package.
    if has_section "$conf" "update_manager cartographer" && grep -q "cartographer3d-plugin-k2openhost" "$conf"; then
        backup_file "$conf"
        python3 - "$conf" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"^\[update_manager cartographer\]\n(?:(?!^\[).*\n)*", "", text, flags=re.M)
open(path, "w").write(text)
PY
    fi
    local tmp
    tmp="$(mktemp -d)"
    git clone -q --depth 1 "$CARTOGRAPHER_REPO" "$tmp/cartographer"
    bash "$tmp/cartographer/scripts/install.sh" --klipper "$KLIPPER_DIR" --klippy-env "$KLIPPY_ENV"
    rm -rf "$tmp"
    add_section "$conf" "update_manager cartographer" <<EOF
type: python
channel: stable
virtualenv: ${KLIPPY_ENV}
project_name: cartographer3d-plugin
is_system_service: False
managed_services: klipper
info_tags:
    desc=Cartographer3D Plugin
EOF
    info "Connect Cartographer to a host USB port: the udev rule names it /dev/k2-cartographer."
    info "PRTouch stays the validated probe; enable Cartographer only after its own tests."
    if confirm "Include cartographer.cfg in printer.cfg now?" n; then
        add_include "$(printer_file cartographer.cfg)"
    fi
    mark_installed cartographer
}

shaketune() {
    step "Klippain Shake&Tune"
    clone_or_update "$SHAKETUNE_REPO" "$SHAKETUNE_DIR" main
    bash "$SHAKETUNE_DIR/install.sh"
    if [[ ! -f "$CONFIG_DIR/shaketune.cfg" ]]; then
        cat > "$CONFIG_DIR/shaketune.cfg" <<'EOF'
# Klippain Shake&Tune (https://github.com/Frix-x/klippain-shaketune)
[shaketune]
# result_folder: ~/printer_data/config/ShakeTune_results
# number_of_results_to_keep: 10
EOF
    fi
    add_include shaketune.cfg
    mark_installed shaketune
}

timelapse() {
    step "Moonraker timelapse"
    [[ -d "$MOONRAKER_DIR" ]] || die "install Moonraker first"
    apt_install ffmpeg
    clone_or_update "$TIMELAPSE_REPO" "$TIMELAPSE_DIR" main
    ln -sf "$TIMELAPSE_DIR/component/timelapse.py" "$MOONRAKER_DIR/moonraker/components/timelapse.py"
    add_section "$(moonraker_conf)" "timelapse" <<EOF
output_path: ${PRINTER_DATA}/timelapse
frame_path: /tmp/timelapse/printer
EOF
    add_section "$(moonraker_conf)" "update_manager timelapse" <<EOF
type: git_repo
primary_branch: main
path: ${TIMELAPSE_DIR}
origin: ${TIMELAPSE_REPO}
managed_services: klipper moonraker
EOF
    mkdir -p "$PRINTER_DATA/timelapse"
    info "The K2 profile already provides timelapse.cfg (macros)."
    restart_service moonraker
    mark_installed timelapse
}

crowsnest() {
    step "Crowsnest (webcam)"
    clone_or_update "$CROWSNEST_REPO" "$CROWSNEST_DIR"
    if [[ "$ASSUME_YES" == "1" ]]; then
        (cd "$CROWSNEST_DIR" && sudo CROWSNEST_UNATTENDED=1 make install)
    else
        (cd "$CROWSNEST_DIR" && sudo make install)
    fi
    mark_installed crowsnest
}

spoolman() {
    step "Spoolman"
    local conf url
    conf="$(moonraker_conf)"
    if has_section "$conf" "spoolman"; then
        ok "[spoolman] is already configured in moonraker.conf"
        return 0
    fi
    printf '    Spoolman server URL (for example http://192.168.1.10:7912): '
    read -r url || url=""
    [[ "$url" =~ ^https?:// ]] || die "a URL starting with http:// or https:// is required"
    backup_file "$conf"
    add_section "$conf" "spoolman" <<EOF
server: ${url}
sync_rate: 5
EOF
    restart_service moonraker
    info "Library profiles and slots keep their spoolman_id links."
    mark_installed spoolman
}

mobileraker() {
    step "Mobileraker companion"
    clone_or_update "https://github.com/Clon1998/mobileraker_companion.git" "$HOME/mobileraker_companion" main
    "$HOME/mobileraker_companion/scripts/install.sh"
    mark_installed mobileraker
}

octoeverywhere() {
    step "OctoEverywhere"
    clone_or_update "https://github.com/QuinnDamerell/OctoPrint-OctoEverywhere.git" "$HOME/octoeverywhere"
    (cd "$HOME/octoeverywhere" && ./install.sh)
    mark_installed octoeverywhere
}

case "${1:-}" in
    hostmcu|cartographer|shaketune|timelapse|crowsnest|spoolman|mobileraker|octoeverywhere) "$1" ;;
    *) die "usage: $0 hostmcu|cartographer|shaketune|timelapse|crowsnest|spoolman|mobileraker|octoeverywhere" ;;
esac
