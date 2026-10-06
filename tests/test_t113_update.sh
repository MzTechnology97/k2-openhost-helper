#!/usr/bin/env bash
# t113 update: only on a running slot B, never during a print, --check before
# anything is written, the reboot only when asked.
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

# A bootstrap checkout with the update scripts; the bundle step is faked.
T113_DIR="$TMP/bootstrap"
mkdir -p "$T113_DIR"
printf '#!/bin/sh\n' > "$T113_DIR/update-slot-b.sh"
printf '#!/bin/bash\nmkdir -p "$2"; echo bundle > "$2/rootfs.tar"\n' > "$T113_DIR/make-update-bundle.sh"
WORK_DIR="$TMP/work"
T113_IP=192.0.2.10

apt_install() { :; }
clone_or_update() { :; }
connect() { :; }
upload() { echo "upload $2" >> "$TMP/log"; }
reboot_printer() { echo "reboot" >> "$TMP/log"; }
SLOT=B
remote_facts() { echo "slot=$SLOT"; }
PRINT_STATE=standby
curl() { echo "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"$PRINT_STATE\"}}}}"; }
REBOOT_MARK=0
t113_ssh() {
    echo "ssh $*" >> "$TMP/log"
    case "$*" in
        *"test -f /tmp/k2oh-update-reboot"*) [[ "$REBOOT_MARK" == 1 ]] ;;
        *) return 0 ;;
    esac
}
ANSWERS=()
confirm() {
    local answer="${ANSWERS[0]:-n}"
    ANSWERS=("${ANSWERS[@]:1}")
    echo "confirm $1 -> $answer" >> "$TMP/log"
    [[ "$answer" == y ]]
}
reset() { rm -f "$TMP/log"; touch "$TMP/log"; }

# 1. On slot A: refused before anything is copied.
reset; SLOT=A
( cmd_update ) >/dev/null 2>&1 && fail_test "update accepted on slot A"
grep -q upload "$TMP/log" && fail_test "copied to a slot A printer"
SLOT=B

# 2. During a print: refused.
reset; PRINT_STATE=printing
( cmd_update ) >/dev/null 2>&1 && fail_test "update accepted during a print"
grep -q upload "$TMP/log" && fail_test "copied during a print"
PRINT_STATE=standby

# 3. The user says no after --check: nothing applied, the copy removed.
reset; ANSWERS=(n)
( cmd_update ) >/dev/null 2>&1 || fail_test "update with 'no' failed"
grep -q "update-slot-b.sh  --check" "$TMP/log" || fail_test "no --check: $(cat "$TMP/log")"
grep -q "update-slot-b.sh $" "$TMP/log" && fail_test "applied although the user said no"
grep -q "rm -rf '/mnt/UDISK/k2oh-update'" "$TMP/log" || fail_test "the copy was not removed"

# 4. Yes: --check, then apply; a boot-time change offers a reboot, declined.
reset; ANSWERS=(y n); REBOOT_MARK=1
( cmd_update ) >/dev/null 2>&1 || fail_test "update failed"
check_line="$(grep -n "update-slot-b.sh  --check" "$TMP/log" | cut -d: -f1)"
apply_line="$(grep -n "update-slot-b.sh $" "$TMP/log" | cut -d: -f1)"
[[ -n "$check_line" && -n "$apply_line" && "$check_line" -lt "$apply_line" ]] \
    || fail_test "--check must run before the update: $(cat "$TMP/log")"
grep -q "^reboot" "$TMP/log" && fail_test "rebooted although the user said no"

# 5. Reboot accepted.
reset; ANSWERS=(y y); REBOOT_MARK=1
( cmd_update ) >/dev/null 2>&1 || fail_test "update with reboot failed"
grep -q "^reboot" "$TMP/log" || fail_test "no reboot after yes"

# 6. --revert: runs the revert check and apply, no bundle build.
reset; ANSWERS=(y); REBOOT_MARK=0
( cmd_update --revert ) >/dev/null 2>&1 || fail_test "revert failed"
grep -q "update-slot-b.sh --revert --check" "$TMP/log" || fail_test "no revert check: $(cat "$TMP/log")"
grep -q "update-slot-b.sh --revert$" "$TMP/log" || fail_test "no revert apply"

# 7. A bootstrap without the update scripts: refused.
rm "$T113_DIR/update-slot-b.sh"
reset
( cmd_update ) >/dev/null 2>&1 && fail_test "update accepted with an old bootstrap"

echo "t113 update tests: PASS"
