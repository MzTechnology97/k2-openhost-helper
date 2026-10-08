#!/usr/bin/env bash
# release status/apply: read-only status, never during a print, fast-forward
# only (no downgrade, no local changes lost), Klipper restarted only when
# asked and with the heaters off, Mainsail pinned to the release tag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HELPER_DIR="$ROOT" K2OH_RELEASE_LIB_ONLY=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
export KLIPPER_DIR="$TMP/klipper" KLIPPY_ENV="$TMP/env" MAINSAIL_DIR="$TMP/mainsail"
export K2OH_T113_DIR="$TMP/no-bootstrap" K2OH_HELPER_REPO_DIR="$TMP/helper"
export K2OH_RELEASE_MANIFEST="$TMP/stable.json"
# shellcheck source=/dev/null
source "$ROOT/scripts/release.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

# Kalico: origin with three commits on the release branch, checkout on the first.
git init -q --bare "$TMP/origin.git"
git init -q "$TMP/work"
git -C "$TMP/work" checkout -q -b k2-pro-openhost
for n in 1 2 3; do
    echo "$n" > "$TMP/work/file"
    git -C "$TMP/work" add file
    git -C "$TMP/work" commit -q -m "c$n"
done
git -C "$TMP/work" push -q "$TMP/origin.git" k2-pro-openhost
C1="$(git -C "$TMP/work" rev-parse HEAD~2)"
C2="$(git -C "$TMP/work" rev-parse HEAD~1)"
C3="$(git -C "$TMP/work" rev-parse HEAD)"
git clone -q -b k2-pro-openhost "$TMP/origin.git" "$KLIPPER_DIR"
git -C "$KLIPPER_DIR" reset -q --hard "$C1"
mkdir -p "$KLIPPY_ENV/bin"
printf '#!/bin/sh\necho pip >> "%s/log"\n' "$TMP" > "$KLIPPY_ENV/bin/pip"
chmod +x "$KLIPPY_ENV/bin/pip"
git clone -q -b k2-pro-openhost "$TMP/origin.git" "$K2OH_HELPER_REPO_DIR"

mkdir -p "$MAINSAIL_DIR"
set_mainsail() { printf '{"version":"%s"}\n' "$1" > "$MAINSAIL_DIR/release_info.json"; }
set_mainsail v2.19.0-k2oh.17

T113_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
write_manifest() {
    cat > "$K2OH_RELEASE_MANIFEST" <<JSON
{"schema": 1, "name": "test", "date": "2026-10-08", "summary": "test release",
 "components": {
  "kalico": {"repo": "o/k", "branch": "k2-pro-openhost", "sha": "$1"},
  "mainsail": {"repo": "o/m", "branch": "develop", "sha": "$C1", "tag": "v2.19.0-k2oh.18"},
  "helper": {"repo": "o/h", "branch": "main", "sha": "$C3", "version": "0.1.0"},
  "t113_bootstrap": {"repo": "o/t", "branch": "main", "sha": "$T113_SHA", "version": "0.1.3"}},
 "tested_with": {"board_firmware": "1.1.7.0"}}
JSON
}
write_manifest "$C2"

PRINT_STATE=standby
HEATERS=off
klipper_is_printing() { [[ "$PRINT_STATE" == printing || "$PRINT_STATE" == paused ]]; }
heaters_off() { [[ "$HEATERS" == off ]]; }
restart_service() { echo "restart $1" >> "$TMP/log"; }
refresh_cartographer_loader() { :; }
run_mainsail_update() { echo "mainsail $1" >> "$TMP/log"; set_mainsail "$1"; }
run_t113_update() { echo "t113 $1" >> "$TMP/log"; }
ANSWERS=()
confirm() {
    local answer="${ANSWERS[0]:-n}"
    ANSWERS=("${ANSWERS[@]:1}")
    echo "confirm $1 -> $answer" >> "$TMP/log"
    [[ "$answer" == y ]]
}
reset() { rm -f "$TMP/log"; touch "$TMP/log"; }
head_is() { [[ "$(git -C "$KLIPPER_DIR" rev-parse HEAD)" == "$1" ]]; }

# 1. status: read-only, shows what is behind and what is missing.
reset
out="$(cmd_status 2>&1)"
grep -q "Kalico .*1 commit(s) behind the release" <<<"$out" || fail_test "status kalico: $out"
grep -q "Mainsail .*v2.19.0-k2oh.17 .*release: v2.19.0-k2oh.18" <<<"$out" || fail_test "status mainsail: $out"
grep -q "Installer helper .*on the release" <<<"$out" || fail_test "status helper: $out"
grep -q "T113 bootstrap .*not installed" <<<"$out" || fail_test "status t113: $out"
grep -q "board_firmware: 1.1.7.0" <<<"$out" || fail_test "status tested_with: $out"
head_is "$C1" || fail_test "status moved Kalico"
[[ -s "$TMP/log" ]] && fail_test "status asked or changed something: $(cat "$TMP/log")"

# 2. During a print: refused before anything moves.
reset; PRINT_STATE=printing
( cmd_apply ) >/dev/null 2>&1 && fail_test "apply accepted during a print"
head_is "$C1" || fail_test "Kalico moved during a print"
grep -q mainsail "$TMP/log" && fail_test "Mainsail installed during a print"
PRINT_STATE=standby

# 3. Idle: Kalico fast-forwards to the release (not past it), Klipper restarts
#    only after a yes, Mainsail gets the release tag.
reset; ANSWERS=(y y y)
cmd_apply >/dev/null 2>&1 || fail_test "apply failed"
head_is "$C2" || fail_test "Kalico not at the release commit"
grep -q "^pip" "$TMP/log" || fail_test "requirements not installed"
grep -q "restart klipper" "$TMP/log" || fail_test "Klipper not restarted after a yes"
grep -q "mainsail v2.19.0-k2oh.18" "$TMP/log" || fail_test "Mainsail not pinned to the tag"
grep -q "^t113" "$TMP/log" && fail_test "T113 updated without --t113"

# 4. Again: nothing to do, nothing asked.
reset; ANSWERS=()
cmd_apply >/dev/null 2>&1 || fail_test "second apply failed"
grep -q "confirm\|restart\|mainsail v" "$TMP/log" && fail_test "second apply did something: $(cat "$TMP/log")"

# 5. Newer than the release: never a downgrade.
reset; git -C "$KLIPPER_DIR" merge -q --ff-only "$C3"; set_mainsail v2.19.0-k2oh.20
cmd_apply >/dev/null 2>&1 || fail_test "apply on a newer checkout failed"
head_is "$C3" || fail_test "Kalico downgraded"
grep -q "mainsail v" "$TMP/log" && fail_test "Mainsail downgraded"
set_mainsail v2.19.0-k2oh.18

# 6. Local changes: the checkout is left as it is.
reset; git -C "$KLIPPER_DIR" reset -q --hard "$C1"; echo dirty > "$KLIPPER_DIR/file"; ANSWERS=(y y)
cmd_apply >/dev/null 2>&1 || fail_test "apply with local changes failed"
head_is "$C1" || fail_test "Kalico moved over local changes"
[[ "$(cat "$KLIPPER_DIR/file")" == dirty ]] || fail_test "local change lost"
git -C "$KLIPPER_DIR" checkout -q -- file

# 7. Heaters on: Kalico moves, Klipper is not restarted and not even asked.
reset; HEATERS=on; ANSWERS=(y y)
cmd_apply >/dev/null 2>&1 || fail_test "apply with heaters on failed"
head_is "$C2" || fail_test "Kalico not moved with heaters on"
grep -q "restart klipper\|Restart Klipper" "$TMP/log" && fail_test "restart offered with a heater on"
HEATERS=off

# 8. A no to the restart: nothing restarted.
reset; git -C "$KLIPPER_DIR" reset -q --hard "$C1"; ANSWERS=(y n)
cmd_apply >/dev/null 2>&1 || fail_test "apply with a no failed"
head_is "$C2" || fail_test "Kalico not moved"
grep -q "restart klipper" "$TMP/log" && fail_test "Klipper restarted after a no"

# 9. --t113: the T113 update is pinned to the release bootstrap commit.
reset; ANSWERS=()
cmd_apply --t113 >/dev/null 2>&1 || fail_test "apply --t113 failed"
grep -q "t113 $T113_SHA" "$TMP/log" || fail_test "T113 update not pinned"
( cmd_apply --bogus ) >/dev/null 2>&1 && fail_test "unknown option accepted"

# 10. Mainsail built from source (upstream release_info.json): compared by
#     the source checkout's commit; not comparable means asked, default no.
export MAINSAIL_SRC_DIR="$TMP/mainsail-src"
git clone -q -b k2-pro-openhost "$TMP/origin.git" "$MAINSAIL_SRC_DIR"
git -C "$MAINSAIL_SRC_DIR" reset -q --hard "$C1"
set_mainsail v2.19.0
reset
out="$(cmd_status 2>&1)"
grep -q "Mainsail .*source ${C1:0:7}.*on the release" <<<"$out" || fail_test "source build status: $out"
cmd_apply >/dev/null 2>&1 || fail_test "apply on a source build failed"
grep -q "mainsail v" "$TMP/log" && fail_test "source build on the release reinstalled"
reset; git -C "$MAINSAIL_SRC_DIR" merge -q --ff-only "$C2"
cmd_apply >/dev/null 2>&1 || fail_test "apply on a newer source build failed"
grep -q "mainsail v" "$TMP/log" && fail_test "newer source build replaced"
reset; rm -rf "$MAINSAIL_SRC_DIR"; ANSWERS=()
cmd_apply >/dev/null 2>&1 || fail_test "apply on an unknown build failed"
grep -q "confirm Install Mainsail" "$TMP/log" || fail_test "unknown build not asked"
grep -q "mainsail v" "$TMP/log" && fail_test "unknown build replaced without a yes"

# 11. Invalid manifest: refused.
write_manifest "not-a-sha"
( cmd_status ) >/dev/null 2>&1 && fail_test "invalid manifest accepted"

echo "release tests: ok"
