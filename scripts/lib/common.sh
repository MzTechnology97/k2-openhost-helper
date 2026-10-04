#!/usr/bin/env bash
# Shared helpers for the K2-OpenHost host installer.
# Sourced by helper.sh and every scripts/*.sh component.
# shellcheck disable=SC2034  # variables are used by the sourcing scripts

# --- paths and sources (override through the environment) ------------------
HELPER_DIR="${HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPTS_DIR="${HELPER_DIR}/scripts"
FILES_DIR="${HELPER_DIR}/files"

PRINTER_DATA="${PRINTER_DATA:-${HOME}/printer_data}"
CONFIG_DIR="${PRINTER_DATA}/config"
LOGS_DIR="${PRINTER_DATA}/logs"
GCODES_DIR="${PRINTER_DATA}/gcodes"
COMMS_DIR="${PRINTER_DATA}/comms"
SYSTEMD_ENV_DIR="${PRINTER_DATA}/systemd"
BACKUP_DIR="${BACKUP_DIR:-${HOME}/k2-openhost-backups}"
STATE_DIR="${HOME}/.k2-openhost-installer-helper"

KLIPPER_DIR="${KLIPPER_DIR:-${HOME}/klipper}"
KLIPPY_ENV="${KLIPPY_ENV:-${HOME}/klippy-env}"
MOONRAKER_DIR="${MOONRAKER_DIR:-${HOME}/moonraker}"
MOONRAKER_ENV="${MOONRAKER_ENV:-${HOME}/moonraker-env}"
MAINSAIL_DIR="${MAINSAIL_DIR:-${HOME}/mainsail}"

KALICO_REPO="${KALICO_REPO:-https://github.com/MzTechnology97/kalico-k2pro.git}"
KALICO_BRANCH="${KALICO_BRANCH:-k2-pro-openhost}"
MOONRAKER_REPO="${MOONRAKER_REPO:-https://github.com/Arksine/moonraker.git}"
MAINSAIL_GH_REPO="${MAINSAIL_GH_REPO:-MzTechnology97/mainsail-k2openhost}"
# Official Cartographer3D plugin (it supports Kalico and the K2 directly).
CARTOGRAPHER_REPO="${CARTOGRAPHER_REPO:-https://github.com/Cartographer3D/cartographer3d-plugin.git}"
# Former K2-OpenHost fork, migrated away when found.
LEGACY_CARTOGRAPHER_DIR="${HOME}/cartographer3d-plugin-k2openhost"
SHAKETUNE_REPO="${SHAKETUNE_REPO:-https://github.com/Frix-x/klippain-shaketune.git}"
SHAKETUNE_DIR="${SHAKETUNE_DIR:-${HOME}/klippain_shaketune}"
TIMELAPSE_REPO="${TIMELAPSE_REPO:-https://github.com/mainsail-crew/moonraker-timelapse.git}"
TIMELAPSE_DIR="${TIMELAPSE_DIR:-${HOME}/moonraker-timelapse}"
CROWSNEST_REPO="${CROWSNEST_REPO:-https://github.com/mainsail-crew/crowsnest.git}"
CROWSNEST_DIR="${CROWSNEST_DIR:-${HOME}/crowsnest}"

# The three T113 USB gadget serial channels (USB_GADGET.md in K2-OpenHost).
GADGET_VENDOR="0525"
GADGET_PRODUCT="a4a6"
K2_MAIN_TTY="${K2_MAIN_TTY:-/dev/ttyUSB0}"
K2_NOZZLE_TTY="${K2_NOZZLE_TTY:-/dev/ttyUSB1}"
K2_RS485_TTY="${K2_RS485_TTY:-/dev/ttyUSB2}"

ASSUME_YES="${ASSUME_YES:-0}"

# --- output ------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m'; C_WHITE=$'\033[1;37m'; C_DIM=$'\033[2m'; C_NC=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_WHITE=""; C_DIM=""; C_NC=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_NC" "$C_WHITE" "$*" "$C_NC"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✔%s %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn()  { printf '    %s!%s %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
fail()  { printf '    %s✘%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()   { fail "$*"; exit 1; }

confirm() {
    # confirm "question" [default y|n]
    local question="$1" default="${2:-y}" answer hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    if [[ "$ASSUME_YES" == "1" ]]; then
        return 0
    fi
    printf '    %s %s ' "$question" "$hint"
    read -r answer || answer=""
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# --- checks ------------------------------------------------------------------
require_not_root() {
    if [[ "$(id -u)" == "0" ]]; then
        die "Run this as the user that will own Klipper (not root). sudo is used when needed."
    fi
}

require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        info "Some steps need sudo; you may be asked for your password."
        sudo -v || die "sudo is required."
    fi
}

require_debian() {
    if ! command -v apt-get >/dev/null 2>&1; then
        die "Only Debian-based hosts (Raspberry Pi OS, Debian, Ubuntu, Armbian) are supported."
    fi
}

os_summary() {
    local pretty="unknown"
    [[ -r /etc/os-release ]] && pretty="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
    printf '%s, %s, Python %s' "$pretty" "$(uname -m)" "$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
}

# --- packages ----------------------------------------------------------------
APT_UPDATED=0
apt_install() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi
    if [[ "$APT_UPDATED" == "0" ]]; then
        info "apt-get update"
        sudo apt-get update -qq
        APT_UPDATED=1
    fi
    info "apt-get install ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

# --- git ---------------------------------------------------------------------
git_origin() {
    git -C "$1" config --get remote.origin.url 2>/dev/null || true
}

same_repo() {
    # same_repo url1 url2: compare GitHub owner/name ignoring .git and scheme
    local a b
    a="$(echo "$1" | sed -E 's#^(https?://|git@)##; s#:#/#; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]')"
    b="$(echo "$2" | sed -E 's#^(https?://|git@)##; s#:#/#; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]')"
    [[ "$a" == "$b" ]]
}

# clone_or_update <url> <dir> [branch]
# An existing checkout of another repository is moved aside, never deleted.
clone_or_update() {
    local url="$1" dir="$2" branch="${3:-}"
    if [[ -d "$dir/.git" ]]; then
        if same_repo "$(git_origin "$dir")" "$url"; then
            info "updating $(basename "$dir")"
            git -C "$dir" fetch -q origin
            if [[ -n "$branch" ]]; then
                if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
                    warn "$dir has local changes; leaving the checkout as it is."
                    return 0
                fi
                git -C "$dir" checkout -q "$branch" 2>/dev/null \
                    || git -C "$dir" checkout -q -b "$branch" "origin/$branch"
                git -C "$dir" merge -q --ff-only "origin/$branch" \
                    || warn "$dir cannot fast-forward to origin/$branch; leaving it as it is."
            else
                git -C "$dir" pull -q --ff-only || warn "$dir cannot fast-forward; leaving it as it is."
            fi
            return 0
        fi
        local aside
        aside="${dir}.before-k2openhost-$(date +%Y%m%d-%H%M%S)"
        warn "$dir is a checkout of $(git_origin "$dir"); moving it to $aside"
        confirm "Move it aside and clone $url?" y || die "Aborted."
        mv "$dir" "$aside"
    elif [[ -e "$dir" ]]; then
        local aside
        aside="${dir}.before-k2openhost-$(date +%Y%m%d-%H%M%S)"
        warn "$dir exists and is not a git checkout; moving it to $aside"
        confirm "Move it aside?" y || die "Aborted."
        mv "$dir" "$aside"
    fi
    info "cloning $url ${branch:+($branch)}"
    if [[ -n "$branch" ]]; then
        git clone -q --filter=blob:none -b "$branch" "$url" "$dir"
    else
        git clone -q --filter=blob:none "$url" "$dir"
    fi
}

# --- files -------------------------------------------------------------------
backup_file() {
    # backup_file <path>: copy next to the original with a timestamp
    local path="$1"
    [[ -e "$path" ]] || return 0
    local copy
    copy="${path}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$copy"
    info "backup: $copy"
}

# render_template <src> <dst>: replace @USER@, @HOME@, @PRINTER_DATA@ ...
render_template() {
    local src="$1" dst="$2"
    sed -e "s#@USER@#$(id -un)#g" \
        -e "s#@HOME@#${HOME}#g" \
        -e "s#@PRINTER_DATA@#${PRINTER_DATA}#g" \
        -e "s#@KLIPPER_DIR@#${KLIPPER_DIR}#g" \
        -e "s#@KLIPPY_ENV@#${KLIPPY_ENV}#g" \
        -e "s#@MAINSAIL_DIR@#${MAINSAIL_DIR}#g" \
        -e "s#@MAINSAIL_GH_REPO@#${MAINSAIL_GH_REPO}#g" \
        -e "s#@HELPER_DIR@#${HELPER_DIR}#g" \
        "$src" > "$dst"
}

# install a root-owned file from a template
sudo_render() {
    local src="$1" dst="$2" mode="${3:-644}" tmp
    tmp="$(mktemp)"
    render_template "$src" "$tmp"
    sudo install -D -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
}

# --- moonraker.conf sections -------------------------------------------------
moonraker_conf() { echo "${CONFIG_DIR}/moonraker.conf"; }

has_section() {
    # has_section <file> "<section name>"
    [[ -f "$1" ]] && grep -Eq "^\[$(printf '%s' "$2" | sed 's/[][\.*^$]/\\&/g')\]" "$1"
}

# add_section <file> "<section name>" <<'EOF' ... EOF  (body on stdin)
add_section() {
    local file="$1" name="$2" body
    body="$(cat)"
    if has_section "$file" "$name"; then
        info "[$name] already in $(basename "$file")"
        return 0
    fi
    printf '\n[%s]\n%s\n' "$name" "$body" >> "$file"
    ok "added [$name] to $(basename "$file")"
}

# --- feature state -----------------------------------------------------------
mark_installed() { mkdir -p "$STATE_DIR"; date -Iseconds > "$STATE_DIR/$1"; }
mark_removed()   { rm -f "$STATE_DIR/$1"; }
is_installed()   { [[ -f "$STATE_DIR/$1" ]]; }

service_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }

restart_service() {
    local name="$1"
    if service_exists "$name"; then
        sudo systemctl restart "$name" && ok "restarted $name" || warn "could not restart $name"
    fi
}

# Cartographer is not part of kalico-k2pro: the official plugin is a pip
# package in the Klippy environment plus a one-line loader in klippy/plugins
# (ignored by Git). Keep that loader present, and only once, after Kalico
# changes.
CARTOGRAPHER_LOADER="from cartographer.extra import *"

refresh_cartographer_loader() {
    "$KLIPPY_ENV/bin/pip" show cartographer3d-plugin >/dev/null 2>&1 || return 0
    local plugins="$KLIPPER_DIR/klippy/plugins" extra="$KLIPPER_DIR/klippy/extras/cartographer.py"
    [[ -d "$plugins" ]] || return 0
    if [[ -e "$extra" ]] && ! git -C "$KLIPPER_DIR" ls-files --error-unmatch klippy/extras/cartographer.py >/dev/null 2>&1; then
        rm -f "$extra"
        info "removed an old Cartographer loader from klippy/extras"
    fi
    printf '%s\n' "$CARTOGRAPHER_LOADER" > "$plugins/cartographer.py"
    ok "Cartographer loader in klippy/plugins"
}

klipper_is_printing() {
    local state
    state="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null || true)"
    [[ "$state" == "printing" || "$state" == "paused" ]]
}

guard_not_printing() {
    if klipper_is_printing; then
        die "A print is running or paused. Try again when the printer is idle."
    fi
}
