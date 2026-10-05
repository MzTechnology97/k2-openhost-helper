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
# Klipper must be the only reader of each channel: a second reader steals
# bytes. The retired Cartographer MUX demux did this to RS-485. Processes of
# this user are checked by their open files; the others (root) only by the
# device named on their command line, because their files need root to read.
if service_exists k2-openhost-demux; then
    bad "the retired Cartographer MUX demux (k2-openhost-demux) is installed; 'scripts/system.sh retire-demux' removes it"
fi
channels=()
for link in /dev/serial/by-id/*Gadget_Serial-if0[0-2]-port0; do
    [[ -e "$link" ]] && channels+=("$(readlink -f "$link")")
done
channel_re='/dev/(ttyUSB[0-9]+|serial/by-id/[^ ]*Gadget_Serial[^ ]*|k2-(main|nozzle|rs485))'
shell_re='(^|/)(ba|da|a|z)?sh$'
readers=0
for proc in /proc/[0-9]*; do
    pid="${proc#/proc/}"
    [[ "$pid" == "$$" ]] && continue
    cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null)" || continue
    [[ -n "$cmd" && "$cmd" != *klippy* ]] || continue
    hit=""
    if [[ -r "$proc/fd" ]]; then
        for fd in "$proc"/fd/*; do
            target="$(readlink "$fd" 2>/dev/null)" || continue
            for dev in "${channels[@]}"; do
                [[ "$target" == "$dev" ]] && hit="$dev"
            done
        done
    elif [[ "$cmd" =~ $channel_re ]]; then
        hit="${BASH_REMATCH[0]}"
        [[ "${cmd%% *}" =~ $shell_re ]] && hit=""
    fi
    [[ -n "$hit" ]] || continue
    bad "process $pid also uses $hit: ${cmd:0:100}"
    readers=$((readers + 1))
done
(( readers )) || ok "no other process uses the K2 channels"

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

step "Cartographer"
carto_loaders=()
for loader in "$KLIPPER_DIR/klippy/extras/cartographer.py" "$KLIPPER_DIR/klippy/plugins/cartographer.py"; do
    [[ -e "$loader" ]] && carto_loaders+=("${loader#"$KLIPPER_DIR"/}")
done
carto_location="$("$KLIPPY_ENV/bin/pip" show cartographer3d-plugin 2>/dev/null | sed -n 's/^Editable project location: //p')"
carto_version="$("$KLIPPY_ENV/bin/pip" show cartographer3d-plugin 2>/dev/null | sed -n 's/^Version: //p')"
if ! "$KLIPPY_ENV/bin/pip" show cartographer3d-plugin >/dev/null 2>&1; then
    info "not installed (optional)"
    (( ${#carto_loaders[@]} )) && bad "a Cartographer loader exists without the package: ${carto_loaders[*]}"
else
    if [[ "$carto_location" == *k2openhost* ]]; then
        bad "Cartographer comes from the former K2-OpenHost fork ($carto_location); run scripts/extras.sh cartographer to switch to the official plugin"
    elif [[ -n "$carto_location" ]]; then
        warn "Cartographer $carto_version is an editable checkout ($carto_location)"
    else
        ok "official Cartographer plugin $carto_version"
    fi
    if [[ "${carto_loaders[*]}" == "klippy/plugins/cartographer.py" ]]; then
        ok "loader klippy/plugins/cartographer.py"
    elif (( ${#carto_loaders[@]} > 1 )); then
        bad "two Cartographer loaders (${carto_loaders[*]}): Kalico refuses to start; run scripts/extras.sh cartographer"
    else
        bad "Cartographer loader: ${carto_loaders[*]:-missing}; run scripts/extras.sh cartographer"
    fi
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
    objects="$(curl -fsS --max-time 3 http://127.0.0.1:7125/printer/objects/list 2>/dev/null || true)"
    while IFS= read -r object; do
        [[ -n "$object" ]] || continue
        link="$(curl -fsS --max-time 3 "http://127.0.0.1:7125/printer/objects/query?${object// /%20}" 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
s = json.load(sys.stdin)["result"]["status"][name]
print("%s %s tx %s rx %s timeouts %s" % (
    s.get("link_state", "-"), name, s.get("tx_frames"), s.get("rx_frames"), s.get("timeouts")))
' "$object" 2>/dev/null || true)"
        case "$link" in
            ok\ *) ok "RS-485 link ${link#ok }" ;;
            lost\ *) bad "RS-485 link LOST: ${link#lost } (check the T113 RS-485 bridge and other readers of the channel)" ;;
            "") warn "$object status not available" ;;
            *) info "RS-485 link state ${link}" ;;
        esac
    done < <(python3 -c '
import json, sys
for o in json.load(sys.stdin)["result"]["objects"]:
    if o.startswith("serial_485"):
        print(o)
' <<<"$objects" 2>/dev/null)
fi

echo
if (( problems )); then
    fail "$problems problem(s) found"
    exit 1
fi
ok "no problems found"
