#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" K2OH_HELPER_LIB_ONLY=1 HELPER_DIR="$ROOT"
mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$ROOT/helper.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }
FW_DIR="$TMP/fw"
mkdir -p "$FW_DIR"
IMAGE="$FW_DIR/cfs0_050_G32-cfs0_000_153-rfid-diag-ro-v2_1.bin"
printf 'experimental-menu-fixture' > "$IMAGE"
SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
cat > "$FW_DIR/manifest.json" <<JSON
{
  "schema": 1,
  "candidates": [
    {
      "id": "fixture",
      "filename": "$(basename "$IMAGE")",
      "sha256": "$SHA",
      "hardware": "cfs0_050_G32",
      "application": "cfs0_000_153",
      "description": "Fixture candidate"
    }
  ]
}
JSON
CUSTOM_CFS_DIR="$FW_DIR"
CUSTOM_CFS_MANIFEST="$FW_DIR/manifest.json"

# Exact acknowledgement must invoke the guarded t113 apply path with the
# manifest SHA and the standard custom-image arguments.
CALLED="$TMP/called"
run() { printf '%s\n' "$*" > "$CALLED"; }
experimental_cfs_menu <<< "FLASH EXPERIMENTAL CFS" > "$TMP/out-ok" 2>&1
[[ -f "$CALLED" ]] || fail_test "correct acknowledgement did not invoke t113 helper"
grep -Fq "t113.sh mcu-fw apply --cfs --cfs-image $IMAGE --cfs-sha256 $SHA" "$CALLED" \
    || fail_test "wrong t113 custom-CFS invocation"
grep -Fq "EXPERIMENTAL FIRMWARE DISCLAIMER" "$TMP/out-ok" \
    || fail_test "disclaimer not shown"
grep -Fq "cfs0_050_G32" "$TMP/out-ok" || fail_test "hardware target missing from disclaimer"
grep -Fq "cfs0_000_153" "$TMP/out-ok" || fail_test "application target missing from disclaimer"

# A wrong phrase must cancel, even if global --yes/unattended mode is enabled.
rm -f "$CALLED"
ASSUME_YES=1
experimental_cfs_menu <<< "yes" > "$TMP/out-no" 2>&1
[[ ! -e "$CALLED" ]] || fail_test "--yes bypassed experimental acknowledgement"
grep -Fq "cancelled" "$TMP/out-no" || fail_test "cancellation not reported"
ASSUME_YES=0

# Hash mismatch must fail before the t113 helper can be invoked.
rm -f "$CALLED"
python3 - "$CUSTOM_CFS_MANIFEST" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
d['candidates'][0]['sha256']='0'*64
json.dump(d, open(p,'w'), indent=2)
PY
(
  experimental_cfs_menu <<< "FLASH EXPERIMENTAL CFS"
) > "$TMP/out-badhash" 2>&1 && fail_test "bad SHA accepted"
[[ ! -e "$CALLED" ]] || fail_test "t113 helper invoked after bad SHA"

# Manifest identity must agree with the filename.
python3 - "$CUSTOM_CFS_MANIFEST" "$SHA" <<'PY'
import json, sys
p,sha=sys.argv[1:]
d=json.load(open(p))
d['candidates'][0]['sha256']=sha
d['candidates'][0]['hardware']='cfs0_050_G30'
json.dump(d, open(p,'w'), indent=2)
PY
(
  experimental_cfs_menu <<< "FLASH EXPERIMENTAL CFS"
) > "$TMP/out-badid" 2>&1 && fail_test "manifest/filename identity mismatch accepted"
[[ ! -e "$CALLED" ]] || fail_test "t113 helper invoked with mismatched identity"

echo "experimental CFS menu tests: PASS"