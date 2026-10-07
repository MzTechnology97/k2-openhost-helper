#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HELPER_DIR="$ROOT" K2OH_T113_LIB_ONLY=1
mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$ROOT/scripts/t113.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

IMAGE="$TMP/cfs0_050_G32-cfs0_000_153-rfid-diag-ro-v2_1.bin"
printf 'offline-candidate-fixture' > "$IMAGE"
SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"

# Local hash mismatch must fail before any SSH/capability probe.
(
  t113_ssh() { echo called >> "$TMP/unexpected-ssh"; }
  stage_custom_cfs_image "$IMAGE" "$(printf '0%.0s' {1..64})"
) >/dev/null 2>&1 && fail_test "wrong SHA accepted"
[[ ! -e "$TMP/unexpected-ssh" ]] || fail_test "SSH used before local SHA validation"


# The installed T113 bootstrap must provide both the custom-image option and
# the newer fail-closed container/result guards before any image is staged.
(
  CALL=0
  t113_ssh() {
    CALL=$((CALL + 1))
    if (( CALL == 1 )); then return 0; fi
    return 1
  }
  stage_custom_cfs_image "$IMAGE" "$SHA"
) >/dev/null 2>&1 && fail_test "custom CFS accepted without the new T113 safety guards"

# cmd_mcu_fw must upload/replace the local path before Klipper is stopped,
# then pass the remote path to k2oh-mcu-fw with quoted host evidence.
(
  STAGED=0 STOPPED=0 CLEANED=0
  T113_IP=192.0.2.10 HOST_IP=192.0.2.20 T113_DIR="$TMP/bootstrap"
  clone_or_update() { :; }
  connect() { :; }
  require_sudo() { :; }
  stage_custom_cfs_image() {
    [[ "$STOPPED" == 0 ]] || fail_test "image staged after Klipper stop"
    [[ "$1" == "$IMAGE" && "${2,,}" == "$SHA" ]] || fail_test "wrong local image/hash"
    CUSTOM_CFS_REMOTE="/mnt/UDISK/.k2openhost/custom-cfs-upload/$SHA/$(basename "$IMAGE")"
    STAGED=1
  }
  stop_klipper_for_flash() { [[ "$STAGED" == 1 ]] || fail_test "Klipper stopped before image validation/stage"; STOPPED=1; }
  host_evidence() { printf '%s' 'proof with spaces'; }
  cleanup_custom_cfs_image() { CLEANED=1; CUSTOM_CFS_REMOTE=""; }
  ssh() {
    local last="${!#}"
    [[ "$STOPPED" == 1 ]] || fail_test "remote updater invoked before Klipper stop"
    [[ "$last" == *"k2oh-mcu-fw"* ]] || fail_test "missing remote k2oh-mcu-fw"
    [[ "$last" == *"--cfs-image"*"/mnt/UDISK/.k2openhost/custom-cfs-upload/"* ]] || fail_test "remote custom path missing"
    [[ "$last" != *"$IMAGE"* ]] || fail_test "CM5-local image path leaked to T113 command"
    [[ "$last" == *"--host-evidence"* ]] || fail_test "host evidence missing"
    return 0
  }
  cmd_mcu_fw apply --cfs --cfs-image "$IMAGE" --cfs-sha256 "$SHA" --yes
  [[ "$CLEANED" == 1 ]] || fail_test "remote custom staging was not cleaned"
)

# Custom images are apply-only and require --cfs.
(
  clone_or_update() { fail_test "network path reached for invalid action"; }
  cmd_mcu_fw update --cfs --cfs-image "$IMAGE" --cfs-sha256 "$SHA"
) >/dev/null 2>&1 && fail_test "custom image accepted with update"
(
  clone_or_update() { fail_test "network path reached without --cfs"; }
  cmd_mcu_fw apply --cfs-image "$IMAGE" --cfs-sha256 "$SHA"
) >/dev/null 2>&1 && fail_test "custom image accepted without --cfs"

echo "t113 custom-CFS orchestration tests: PASS"
