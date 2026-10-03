#!/usr/bin/env bash
# Backup and restore of the printer configuration, the CFS filament library
# and the CFS runtime state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

backup() {
    step "Backing up the configuration"
    mkdir -p "$BACKUP_DIR"
    local archive
    archive="$BACKUP_DIR/k2-openhost-config-$(date +%Y%m%d-%H%M%S).tar.gz"
    local items=(config)
    local extra
    for extra in filament_box.json filament_box.json.pre-library moonraker.asvc database; do
        [[ -e "$PRINTER_DATA/$extra" ]] && items+=("$extra")
    done
    tar -czf "$archive" -C "$PRINTER_DATA" "${items[@]}"
    ok "$archive ($(du -h "$archive" | cut -f1))"
    info "contains: ${items[*]}"
}

restore() {
    step "Restoring a configuration backup"
    guard_not_printing
    local archives=()
    mapfile -t archives < <(ls -1t "$BACKUP_DIR"/k2-openhost-config-*.tar.gz 2>/dev/null || true)
    (( ${#archives[@]} )) || die "no backups in $BACKUP_DIR"
    local i
    for i in "${!archives[@]}"; do
        printf '    %s%2d)%s %s\n' "$C_YELLOW" "$((i + 1))" "$C_NC" "$(basename "${archives[$i]}")"
    done
    local choice
    printf '    Backup to restore: '
    read -r choice || choice=""
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#archives[@]} )) || die "invalid choice"
    local archive="${archives[$((choice - 1))]}"
    confirm "Replace the current configuration with $(basename "$archive")? (a backup of the current one is made first)" n || return 0
    backup
    sudo systemctl stop klipper moonraker 2>/dev/null || true
    tar -xzf "$archive" -C "$PRINTER_DATA"
    sudo systemctl start moonraker klipper 2>/dev/null || true
    ok "restored $(basename "$archive")"
}

case "${1:-backup}" in
    backup) backup ;;
    restore) restore ;;
    *) die "usage: $0 backup|restore" ;;
esac
