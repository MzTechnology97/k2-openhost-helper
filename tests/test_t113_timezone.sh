#!/usr/bin/env bash
# t113 timezone: slot B gets this host's zone through uci; slot A is never
# written; an unreadable host zone or an already matching printer changes
# nothing; boot-b, commit and update apply it too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HELPER_DIR="$ROOT" K2OH_T113_LIB_ONLY=1
export K2OH_GATE_DROPIN="$TMP/no-gate.conf"
mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$ROOT/scripts/t113.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

T113_IP=192.0.2.10
connect() { :; }
SLOT=B
remote_facts() { echo "slot=$SLOT"; }
PRINTER_ZONE="Asia/Shanghai"
t113_ssh() {
    echo "ssh $*" >> "$TMP/log"
    case "$*" in
        *"uci -q get system.@system[0].zonename"*) echo "$PRINTER_ZONE" ;;
        *) return 0 ;;
    esac
}
HOST_TZ=$'Europe/Rome\nCET-1CEST,M3.5.0,M10.5.0/3'
host_timezone() { [[ -n "$HOST_TZ" ]] && printf '%s\n' "$HOST_TZ"; }
reset() { rm -f "$TMP/log"; touch "$TMP/log"; }

# 1. Slot B on China time: the host's zone and POSIX string are written.
reset
out="$(cmd_timezone 2>&1)" || fail_test "timezone failed: $out"
grep -q "zonename='Europe/Rome'" "$TMP/log" || fail_test "zonename not set"
grep -q "timezone='CET-1CEST,M3.5.0,M10.5.0/3'" "$TMP/log" || fail_test "POSIX TZ not set"
grep -q "uci commit system && /etc/init.d/system reload" "$TMP/log" || fail_test "not committed and applied"
grep -q "was Asia/Shanghai" <<<"$out" || fail_test "previous zone not reported: $out"

# 2. Already on the host's zone: nothing written.
reset; PRINTER_ZONE="Europe/Rome"
out="$(cmd_timezone 2>&1)"
grep -q "uci set" "$TMP/log" && fail_test "rewrote a matching zone"
grep -q "printer time zone: Europe/Rome" <<<"$out" || fail_test "no confirmation: $out"
PRINTER_ZONE="Asia/Shanghai"

# 3. Slot A (stock system): refused, nothing written.
reset; SLOT=A
( cmd_timezone ) >/dev/null 2>&1 && fail_test "accepted on slot A"
grep -q "uci set" "$TMP/log" && fail_test "wrote slot A"
SLOT=B

# 4. Host zone unreadable: warning only, printer untouched.
reset; HOST_TZ=""
out="$(sync_timezone 2>&1)" || fail_test "sync failed without a host zone"
grep -q "uci set" "$TMP/log" && fail_test "wrote without a host zone"
grep -q "cannot read this host's time zone" <<<"$out" || fail_test "no warning: $out"
HOST_TZ=$'Europe/Rome\nCET-1CEST,M3.5.0,M10.5.0/3'

# 5. commit applies it after keeping slot B.
reset
cmd_commit >/dev/null 2>&1 || fail_test "commit failed"
grep -q "k2oh-slot commit" "$TMP/log" || fail_test "commit not run"
grep -q "zonename='Europe/Rome'" "$TMP/log" || fail_test "commit did not set the zone"

# 6. host_timezone itself, on this machine: zone and POSIX string, or nothing.
unset -f host_timezone
# shellcheck source=/dev/null
K2OH_T113_LIB_ONLY=1 source "$ROOT/scripts/t113.sh"
if real="$(host_timezone)"; then
    [[ "$(wc -l <<<"$real")" == 2 ]] || fail_test "host_timezone: not two lines: $real"
    [[ -f "/usr/share/zoneinfo/$(sed -n 1p <<<"$real")" ]] || fail_test "unknown zone: $real"
fi

echo "test_t113_timezone: OK"
