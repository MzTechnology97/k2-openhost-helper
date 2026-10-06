#!/usr/bin/env bash
# The installer helper offers to update itself when its branch has new commits.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" K2OH_HELPER_LIB_ONLY=1 HELPER_DIR="$ROOT"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

# A published helper repository and a user's checkout of it.
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/publish" 2>/dev/null
echo 1 > "$TMP/publish/VERSION"
git -C "$TMP/publish" add VERSION && git -C "$TMP/publish" commit -qm "first"
git -C "$TMP/publish" push -q origin HEAD:main
git clone -q "$TMP/origin.git" "$TMP/checkout"
publish_commit() {
    echo "$1" > "$TMP/publish/VERSION"
    git -C "$TMP/publish" commit -qam "$1" && git -C "$TMP/publish" push -q origin HEAD:main
}

# shellcheck source=/dev/null
source "$ROOT/helper.sh"
export K2OH_HELPER_REPO_DIR="$TMP/checkout"
HELPER_REPO_DIR="$TMP/checkout"
interactive_terminal() { return 0; }
restart_helper() { touch "$TMP/restarted"; }
ANSWER=y
confirm() { [[ "$ANSWER" == y ]]; }
head_version() { cat "$TMP/checkout/VERSION"; }

# 1. Nothing new: silent, no restart.
out="$(check_helper_update 2>&1)"
[[ -z "$out" && ! -e "$TMP/restarted" ]] || fail_test "an up-to-date helper said: $out"

# 2. New commit, the user says no: shown, not applied.
publish_commit 2
ANSWER=n
out="$(check_helper_update 2>&1)"
[[ "$out" == *"update available"* && "$out" == *"1 new commit"* ]] || fail_test "no notice: $out"
[[ "$(head_version)" == 1 && ! -e "$TMP/restarted" ]] || fail_test "updated although the user said no"

# 3. --yes only reports.
ASSUME_YES=1 ANSWER=y
check_helper_update >/dev/null 2>&1
[[ "$(head_version)" == 1 ]] || fail_test "--yes updated the helper"
ASSUME_YES=0

# 4. Local changes are never touched.
echo local > "$TMP/checkout/VERSION"
out="$(check_helper_update 2>&1)"
[[ "$out" == *"local changes"* && "$(head_version)" == local ]] || fail_test "local changes: $out"
git -C "$TMP/checkout" checkout -q VERSION

# 5. No terminal or K2OH_NO_UPDATE_CHECK=1: no check at all.
interactive_terminal() { return 1; }
[[ -z "$(check_helper_update 2>&1)" ]] || fail_test "checked without a terminal"
interactive_terminal() { return 0; }
K2OH_NO_UPDATE_CHECK=1
[[ -z "$(check_helper_update 2>&1)" ]] || fail_test "checked with K2OH_NO_UPDATE_CHECK=1"
K2OH_NO_UPDATE_CHECK=0

# 6. The user says yes: fast-forward and restart.
ANSWER=y
check_helper_update >/dev/null 2>&1
[[ "$(head_version)" == 2 && -e "$TMP/restarted" ]] || fail_test "not updated or not restarted"

# 7. Not a git checkout: silent.
HELPER_REPO_DIR="$TMP"
[[ -z "$(check_helper_update 2>&1)" ]] || fail_test "outside a checkout"

echo "helper self-update tests: PASS"
