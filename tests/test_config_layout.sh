#!/usr/bin/env bash
# Printer files in macros/ (kalico-k2pro #40) or in the config root (older
# profiles and printers): printer_file and 'config install' follow the layout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail_test() { echo "FAIL: $*" >&2; exit 1; }

setup() {
    rm -rf "$TMP/home" "$TMP/klipper"
    mkdir -p "$TMP/home/printer_data/config" "$TMP/klipper/config/k2"
    export HOME="$TMP/home" HELPER_DIR="$ROOT" KLIPPER_DIR="$TMP/klipper"
    export PRINTER_DATA="$TMP/home/printer_data" K2OH_GATE_DROPIN="$TMP/no-gate.conf"
}
pfile() { (source "$ROOT/scripts/lib/common.sh"; printer_file "$1"); }
cfg() { echo "$PRINTER_DATA/config/printer.cfg"; }

# 1. No printer.cfg yet: the installed profile decides.
setup
[[ "$(pfile k2_t113.cfg)" == "k2_t113.cfg" ]] || fail_test "old profile, no printer.cfg"
mkdir -p "$KLIPPER_DIR/config/k2/macros"
[[ "$(pfile k2_t113.cfg)" == "macros/k2_t113.cfg" ]] || fail_test "new profile, no printer.cfg"

# 2. A printer on the macros/ layout.
printf '[include macros/print.cfg]\n[include macros/motor_control.cfg]\n' > "$(cfg)"
[[ "$(pfile k2_t113.cfg)" == "macros/k2_t113.cfg" ]] || fail_test "macros layout"
[[ "$(pfile cartographer.cfg)" == "macros/cartographer.cfg" ]] || fail_test "macros layout, not included yet"

# 3. A printer set up before: root includes, even with a new profile.
printf '[include macros.cfg]\n[include start_print.cfg]\n[include motor_control.cfg]\n#[include k2_t113.cfg]\n[include macros/shell_command.cfg]\n' > "$(cfg)"
[[ "$(pfile k2_t113.cfg)" == "k2_t113.cfg" ]] || fail_test "root layout, commented include"
[[ "$(pfile motor_control.cfg)" == "motor_control.cfg" ]] || fail_test "root layout, included"
[[ "$(pfile cartographer.cfg)" == "cartographer.cfg" ]] || fail_test "root layout, not included"

# 4. config install with the macros/ profile: files land in macros/.
setup
mkdir -p "$KLIPPER_DIR/config/k2/macros"
printf '[mcu]\nserial: /dev/x\n[include macros/print.cfg]\n' > "$KLIPPER_DIR/config/k2/printer.cfg"
for f in print box box_rfid_diag box_rfid_bambu box_rfid_mifare k2_t113 overrides; do
    echo "[$f]" > "$KLIPPER_DIR/config/k2/macros/$f.cfg"
done
out="$(bash "$ROOT/scripts/config.sh" install 2>&1)" || fail_test "install failed: $out"
for f in print box box_rfid_diag box_rfid_bambu box_rfid_mifare k2_t113 overrides; do
    [[ -f "$PRINTER_DATA/config/macros/$f.cfg" ]] || fail_test "macros/$f.cfg not installed: $out"
    [[ ! -e "$PRINTER_DATA/config/$f.cfg" ]] || fail_test "$f.cfg in the config root"
done
grep -q "still includes printer files" <<<"$out" && fail_test "layout warning on a new install"

# 5. Same profile, printer still on the root layout: kept, with a warning.
setup
mkdir -p "$KLIPPER_DIR/config/k2/macros"
printf '[mcu]\nserial: /dev/x\n[include macros/print.cfg]\n' > "$KLIPPER_DIR/config/k2/printer.cfg"
echo "[print]" > "$KLIPPER_DIR/config/k2/macros/print.cfg"
printf '[mcu]\nserial: /dev/y\n[include macros.cfg]\n[include start_print.cfg]\n' > "$(cfg)"
out="$(bash "$ROOT/scripts/config.sh" install 2>&1)" || fail_test "install failed: $out"
grep -q "still includes printer files" <<<"$out" || fail_test "no layout warning: $out"
grep -q '^\[include macros.cfg\]' "$(cfg)" || fail_test "printer.cfg replaced without --force"
[[ -f "$(cfg).k2oh-new" ]] || fail_test "no printer.cfg.k2oh-new"

# 6. An older Kalico without macros/: the root layout as before.
setup
printf '[mcu]\nserial: /dev/x\n[include box.cfg]\n' > "$KLIPPER_DIR/config/k2/printer.cfg"
echo "[box]" > "$KLIPPER_DIR/config/k2/box.cfg"
out="$(bash "$ROOT/scripts/config.sh" install 2>&1)" || fail_test "legacy install failed: $out"
[[ -f "$PRINTER_DATA/config/box.cfg" ]] || fail_test "legacy box.cfg not in the root"
[[ ! -d "$PRINTER_DATA/config/macros" ]] || fail_test "legacy profile created macros/"

echo "config layout tests: PASS"
