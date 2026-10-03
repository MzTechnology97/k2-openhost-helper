#!/usr/bin/env bash
# Read-only health check of a K2-OpenHost host. Changes nothing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

problems=0
bad() { fail "$*"; problems=$((problems + 1)); }

cfg_serial() {
    # cfg_serial <section regex>: serial: value of that section in printer.cfg
    local cfg="$CONFIG_DIR/printer.cfg"
    [[ -f "$cfg" ]] || return 0
    awk -v sect="$1" '
        /^\[/ { inside = ($0 ~ sect) }
        inside && /^serial:/ { sub(/^serial:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); print; exit }
    ' "$cfg"
}

step "Host"
info "$(os_summary), user $(id -un)"
for group in dialout tty; do
    id -nG | tr ' ' '\n' | grep -qx "$group" && ok "in group $group" || bad "$(id -un) is not in group $group"
done
if systemctl is-active --quiet ModemManager 2>/dev/null; then
    bad "ModemManager is running and may probe the K2 serial channels"
else
    ok "ModemManager is not running"
fi

step "T113 USB gadget"
if lsusb -d "${GADGET_VENDOR}:${GADGET_PRODUCT}" >/dev/null 2>&1; then
    ok "gadget ${GADGET_VENDOR}:${GADGET_PRODUCT} present: $(lsusb -d "${GADGET_VENDOR}:${GADGET_PRODUCT}" | head -1 | cut -d' ' -f7-)"
else
    bad "the K2 gadget (${GADGET_VENDOR}:${GADGET_PRODUCT}) is not connected: check the cable to the K2 service Micro-USB port and the T113 bridge"
fi
declare -A expected=([00]="Main MCU" [01]="Nozzle MCU" [02]="RS-485 / CFS")
declare -A section=([00]='^\[mcu\]$' [01]='^\[mcu nozzle_mcu\]$' [02]='^\[serial_485')
for num in 00 01 02; do
    link="$(ls /dev/serial/by-id/*Gadget_Serial-if${num}-port0 2>/dev/null | head -1)"
    if [[ -z "$link" ]]; then
        bad "interface ${num} (${expected[$num]}) has no device"
        continue
    fi
    dev="$(readlink -f "$link")"
    configured="$(cfg_serial "${section[$num]}")"
    if [[ -z "$configured" ]]; then
        warn "interface ${num} (${expected[$num]}) is $dev; printer.cfg has no matching serial"
    elif [[ "$(readlink -f "$configured" 2>/dev/null)" == "$dev" ]]; then
        ok "interface ${num} (${expected[$num]}) = $dev = printer.cfg $configured"
    else
        bad "interface ${num} (${expected[$num]}) is $dev but printer.cfg uses $configured ('scripts/config.sh serial-names' fixes this)"
    fi
done

step "Services"
for service in klipper moonraker nginx; do
    if systemctl is-active --quiet "$service"; then
        ok "$service active"
    elif service_exists "$service"; then
        bad "$service installed but not active (journalctl -u $service)"
    else
        bad "$service not installed"
    fi
done
for service in klipper-mcu crowsnest; do
    service_exists "$service" && { systemctl is-active --quiet "$service" && ok "$service active" || bad "$service not active"; }
done
[[ -f /etc/systemd/system/klipper.service.d/k2-openhost-transport.conf ]] \
    && ok "Klipper waits for the gadget channels at boot" \
    || warn "Klipper start gate not installed (scripts/kalico.sh install adds it)"

step "Software"
if [[ -d "$KLIPPER_DIR/.git" ]]; then
    info "Kalico: $(git_origin "$KLIPPER_DIR") $(git -C "$KLIPPER_DIR" rev-parse --abbrev-ref HEAD) $(git -C "$KLIPPER_DIR" rev-parse --short HEAD)"
    same_repo "$(git_origin "$KLIPPER_DIR")" "$KALICO_REPO" || bad "$KLIPPER_DIR is not kalico-k2pro"
else
    bad "$KLIPPER_DIR missing"
fi
if [[ -f "$MAINSAIL_DIR/release_info.json" ]]; then
    info "Mainsail: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("project_owner"),d.get("project_name"),d.get("version"))' "$MAINSAIL_DIR/release_info.json")"
else
    warn "Mainsail release_info.json not found in $MAINSAIL_DIR"
fi

step "Klipper and the CFS"
info_json="$(curl -fsS --max-time 3 http://127.0.0.1:7125/printer/info 2>/dev/null || true)"
if [[ -z "$info_json" ]]; then
    bad "Moonraker API not reachable on port 7125"
else
    state="$(python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["state"]+": "+r.get("state_message","").splitlines()[0] if r.get("state_message") else r["state"])' <<<"$info_json" 2>/dev/null)"
    [[ "$state" == ready* ]] && ok "Klipper $state" || bad "Klipper $state"
    box="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?box=api_version,driver_ready,filament_library,observation_mode' 2>/dev/null || true)"
    python3 -c '
import json, sys
data = json.load(sys.stdin)["result"]["status"].get("box")
if not data:
    raise SystemExit(1)
lib = data.get("filament_library") or {}
print("    box api v%s, driver %s, %s" % (
    data.get("api_version"), "ready" if data.get("driver_ready") else "NOT ready",
    "observation mode" if data.get("observation_mode") else "operational mode"))
if lib:
    print("    filament library %s: %s custom + %s system%s" % (
        lib.get("path"), lib.get("custom_count"), lib.get("system_count"),
        "  ERROR: " + lib["error"] if lib.get("error") else ""))
' <<<"$box" 2>/dev/null || warn "box object not available"
fi

echo
if (( problems )); then
    fail "$problems problem(s) found"
    exit 1
fi
ok "no problems found"
