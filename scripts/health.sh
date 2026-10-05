#!/usr/bin/env bash
# Automatic K2-OpenHost check after a boot or a package update.
#
#   scripts/health.sh boot|apt|manual
#
# Run by k2oh-health@boot.service at every boot and by k2oh-health@apt.service
# after apt/dpkg changes (apt hook). It waits for Klipper, runs the read-only
# doctor, keeps the report in printer_data/logs/k2oh-health.log and reports
# the result in the Klipper console (RESPOND), plus an optional command of
# your own (K2OH_HEALTH_NOTIFY_CMD in printer_data/systemd/k2oh-health.env,
# called with the summary as its only argument). Changes nothing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

reason="${1:-manual}"
case "$reason" in
    boot) wait_s="${K2OH_HEALTH_BOOT_WAIT:-240}" ;;
    apt) wait_s="${K2OH_HEALTH_APT_WAIT:-30}" ;;
    manual) wait_s=0 ;;
    *) die "usage: $0 boot|apt|manual" ;;
esac
log_file="${K2OH_HEALTH_LOG:-${LOGS_DIR}/k2oh-health.log}"
moonraker="${K2OH_MOONRAKER:-http://127.0.0.1:7125}"

query() {
    curl -fsS --max-time 3 "${moonraker}$1" 2>/dev/null
}

klippy_state() {
    query /printer/info | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null
}

motors_settled() {
    # ready, or startup finished (failed or not): doctor reports which
    query '/printer/objects/query?motor_control=motor_ready,startup' | python3 -c '
import json, sys
s = json.load(sys.stdin)["result"]["status"].get("motor_control")
if s is None or s.get("motor_ready") or (s.get("startup") or {}).get("complete"):
    raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null
}

# After a boot Klipper, the T113 bridges and the motor startup need time.
deadline=$((SECONDS + wait_s))
while (( SECONDS < deadline )); do
    if [[ "$(klippy_state)" == ready ]] && motors_settled; then
        break
    fi
    sleep 5
done

report="$(NO_COLOR=1 bash "${SCRIPTS_DIR}/doctor.sh" 2>&1)"
rc=$?
extra=""
if [[ "$reason" == apt ]]; then
    if [[ -f /var/run/reboot-required ]]; then
        extra=" A reboot is pending after the update; the check runs again at boot."
    fi
    newest="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$newest" ]] && ! modinfo -k "$newest" usbserial >/dev/null 2>&1; then
        rc=1
        extra+=" usbserial is missing for kernel ${newest}: the T113 channels will not appear after a reboot."
    fi
fi

problems="$(grep -c '✘' <<<"$report" || true)"
if (( rc == 0 )); then
    summary="K2-OpenHost check after ${reason}: OK.${extra}"
else
    first="$(grep '✘' <<<"$report" | grep -v 'problem(s) found' | head -3 \
        | sed -e 's/^ *✘ *//' | paste -sd ';' -)"
    summary="K2-OpenHost check after ${reason}: ${problems:-1} problem(s): ${first}.${extra}"
fi

mkdir -p "$(dirname "$log_file")"
{
    printf '\n===== %s  %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason"
    printf '%s\n' "$report"
    printf '%s\n' "$summary"
} >>"$log_file"
# Keep the log small: last 2000 lines.
tail -n 2000 "$log_file" >"${log_file}.tmp" 2>/dev/null && mv "${log_file}.tmp" "$log_file"

# Klipper console (Mainsail shows it); errors in red.
# K2OH_HEALTH_NO_RESPOND=1 skips it (tests, or a printer you do not want to touch).
msg="$(printf '%s' "$summary" | tr -d '"' | cut -c1-400)"
type=echo
(( rc == 0 )) || type=error
[[ "${K2OH_HEALTH_NO_RESPOND:-0}" == 1 ]] || python3 - "$moonraker" "$type" "$msg" <<'EOF' >/dev/null 2>&1 || true
import json, sys, urllib.request
url, kind, msg = sys.argv[1:4]
body = json.dumps({"script": 'RESPOND TYPE=%s PREFIX="K2-OpenHost" MSG="%s"' % (kind, msg)})
req = urllib.request.Request(url + "/printer/gcode/script", data=body.encode(),
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=5).read()
EOF

env_file="${SYSTEMD_ENV_DIR}/k2oh-health.env"
if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
fi
if [[ -n "${K2OH_HEALTH_NOTIFY_CMD:-}" ]]; then
    bash -c "${K2OH_HEALTH_NOTIFY_CMD} \"\$1\"" _ "$summary" >/dev/null 2>&1 || true
fi

printf '%s\n' "$summary"
exit "$rc"
