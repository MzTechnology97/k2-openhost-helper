#!/usr/bin/env bash
# Mainsail K2-OpenHost fork (CFS panel, filament path, library, print
# mapping) served by nginx on port 80.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MAINSAIL_SRC_DIR="${MAINSAIL_SRC_DIR:-${HOME}/mainsail-k2openhost-src}"

latest_zip_url() {
    # Newest release (pre-releases included) that carries mainsail.zip.
    curl -fsSL "https://api.github.com/repos/${MAINSAIL_GH_REPO}/releases?per_page=20" 2>/dev/null \
        | python3 -c '
import json, sys
for release in json.load(sys.stdin):
    for asset in release.get("assets", []):
        if asset.get("name") == "mainsail.zip":
            print(release["tag_name"], asset["browser_download_url"])
            sys.exit(0)
' 2>/dev/null || true
}

build_from_source() {
    step "Building ${MAINSAIL_GH_REPO} from source"
    local node_major
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if (( node_major < 20 )); then
        die "No prebuilt mainsail.zip was found and Node.js 20+ is not installed. Install Node.js 20 or newer (for example through nvm) and run this step again."
    fi
    clone_or_update "https://github.com/${MAINSAIL_GH_REPO}.git" "$MAINSAIL_SRC_DIR" develop
    (cd "$MAINSAIL_SRC_DIR" && npm ci --no-audit --no-fund && npx vite build)
    rm -rf "${MAINSAIL_DIR}.new"
    cp -a "$MAINSAIL_SRC_DIR/dist" "${MAINSAIL_DIR}.new"
}

install_nginx() {
    step "nginx"
    apt_install nginx
    sudo_render "${FILES_DIR}/nginx/upstreams.conf" /etc/nginx/conf.d/upstreams.conf
    sudo_render "${FILES_DIR}/nginx/common_vars.conf" /etc/nginx/conf.d/common_vars.conf
    sudo_render "${FILES_DIR}/nginx/mainsail" /etc/nginx/sites-available/mainsail
    sudo ln -sf /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        sudo rm -f /etc/nginx/sites-enabled/default
        info "disabled the default nginx site"
    fi
    # nginx (www-data) must be able to traverse the home directory.
    if [[ "$(stat -c '%A' "$HOME" | cut -c10)" != "x" ]]; then
        if confirm "Allow nginx to reach $MAINSAIL_DIR (chmod o+x $HOME)?" y; then
            chmod o+x "$HOME"
        else
            warn "nginx will answer 403 until it can read $MAINSAIL_DIR"
        fi
    fi
    sudo nginx -t -q
    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl restart nginx
    ok "nginx serves $MAINSAIL_DIR on port 80"
}

install_mainsail() {
    step "Mainsail K2-OpenHost"
    apt_install curl unzip
    local found tag url
    found="$(latest_zip_url)"
    if [[ -n "$found" ]]; then
        tag="${found%% *}"; url="${found#* }"
        info "release $tag"
        local tmp
        tmp="$(mktemp -d)"
        curl -fsSL -o "$tmp/mainsail.zip" "$url"
        rm -rf "${MAINSAIL_DIR}.new"
        mkdir -p "${MAINSAIL_DIR}.new"
        unzip -q "$tmp/mainsail.zip" -d "${MAINSAIL_DIR}.new"
        rm -rf "$tmp"
    else
        warn "no prebuilt release found for ${MAINSAIL_GH_REPO}"
        build_from_source
    fi
    if [[ -d "$MAINSAIL_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        tar -czf "$BACKUP_DIR/mainsail-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$(dirname "$MAINSAIL_DIR")" "$(basename "$MAINSAIL_DIR")"
        rm -rf "$MAINSAIL_DIR"
        info "previous web files saved in $BACKUP_DIR"
    fi
    mv "${MAINSAIL_DIR}.new" "$MAINSAIL_DIR"
    ok "installed in $MAINSAIL_DIR"
    install_nginx
    mark_installed mainsail
}

remove_mainsail() {
    step "Removing Mainsail"
    confirm "Remove the nginx site and $MAINSAIL_DIR?" n || return 0
    sudo rm -f /etc/nginx/sites-enabled/mainsail /etc/nginx/sites-available/mainsail
    sudo systemctl reload nginx 2>/dev/null || true
    rm -rf "$MAINSAIL_DIR"
    mark_removed mainsail
    ok "removed"
}

case "${1:-install}" in
    install|update) install_mainsail ;;
    nginx) install_nginx ;;
    remove) remove_mainsail ;;
    *) die "usage: $0 install|update|nginx|remove" ;;
esac
