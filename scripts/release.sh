#!/usr/bin/env bash
# K2-OpenHost releases: the component commits validated together on the
# reference printer, listed in the K2-OpenHost repository
# (releases/stable.json).
#   status          installed versions against the release (read-only; it
#                   only fetches the Git checkouts)
#   apply [--t113]  bring Kalico and Mainsail to the release: never during a
#                   print, never a downgrade (a newer checkout is left as it
#                   is), fast-forward only, Klipper restarted only when asked
#                   and only with the heaters off; --t113 also updates the T113
#                   programs (helper.sh t113 update pinned to the release
#                   bootstrap; its --check shows the changes before asking)
#
# Moving branches (helper.sh update, Moonraker's update manager) still give
# the newest commits; a release is the newest set validated together.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RELEASE_MANIFEST="${K2OH_RELEASE_MANIFEST:-https://raw.githubusercontent.com/MzTechnology97/K2-OpenHost/main/releases/stable.json}"
T113_DIR="${K2OH_T113_DIR:-${HOME}/k2-openhost-t113-bootstrap}"
HELPER_REPO_DIR="${K2OH_HELPER_REPO_DIR:-$HELPER_DIR}"
MOONRAKER_URL="${MOONRAKER_URL:-http://127.0.0.1:7125}"

declare -A REL=()

load_manifest() {
    # Fills REL[] from the manifest (a local file or a URL).
    local json rows key value
    if [[ -f "$RELEASE_MANIFEST" ]]; then
        json="$(cat "$RELEASE_MANIFEST")"
    else
        json="$(curl -fsSL --max-time 20 "$RELEASE_MANIFEST" 2>/dev/null)" \
            || die "cannot download the release manifest: $RELEASE_MANIFEST"
    fi
    rows="$(python3 -c '
import json, re, sys
doc = json.loads(sys.stdin.read())
if doc.get("schema") != 1:
    raise SystemExit("unsupported release manifest schema")
sha = re.compile(r"^[0-9a-f]{40}$")
print("name\t%s" % doc["name"])
print("date\t%s" % doc["date"])
print("summary\t%s" % doc.get("summary", ""))
for comp in ("kalico", "mainsail", "helper", "t113_bootstrap"):
    item = doc["components"][comp]
    if not sha.match(item["sha"]):
        raise SystemExit("%s: invalid commit %r" % (comp, item["sha"]))
    for field in ("repo", "branch", "sha", "tag", "version"):
        if field in item:
            print("%s_%s\t%s" % (comp, field, item[field]))
for key, value in doc.get("tested_with", {}).items():
    print("tested_%s\t%s" % (key, value))
' <<<"$json" 2>&1)" || die "invalid release manifest ($RELEASE_MANIFEST): $rows"
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] && REL["$key"]="${value%$'\r'}"
    done <<<"$rows"
}

fetch_checkout() {
    [[ -d "$1/.git" ]] || return 0
    timeout 30 git -C "$1" fetch -q origin 2>/dev/null \
        || warn "could not fetch $(basename "$1") (no network?): comparing with what is known locally"
}

git_relation() {
    # git_relation DIR SHA: same | behind N | ahead N | diverged | unknown | missing
    local dir="$1" sha="$2" head
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || { echo missing; return; }
    if [[ "$head" == "$sha" ]]; then
        echo same
    elif ! git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo unknown
    elif git -C "$dir" merge-base --is-ancestor "$head" "$sha"; then
        echo "behind $(git -C "$dir" rev-list --count "$head..$sha")"
    elif git -C "$dir" merge-base --is-ancestor "$sha" "$head"; then
        echo "ahead $(git -C "$dir" rev-list --count "$sha..$head")"
    else
        echo diverged
    fi
}

describe_relation() {
    case "$1" in
        same) echo "on the release" ;;
        behind*) echo "${1#behind } commit(s) behind the release" ;;
        ahead*) echo "${1#ahead } commit(s) newer than the release" ;;
        diverged) echo "diverged from the release (local commits)" ;;
        unknown) echo "release commit not found (fetch failed?)" ;;
        missing) echo "not installed" ;;
    esac
}

short_head() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "-"; }

mainsail_installed_tag() {
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
        "$MAINSAIL_DIR/release_info.json" 2>/dev/null || true
}

mainsail_relation() {
    # same | behind | ahead | missing, from the k2oh.N build number
    local installed="$1" wanted="$2"
    [[ -n "$installed" ]] || { echo missing; return; }
    [[ "$installed" == "$wanted" ]] && { echo same; return; }
    local have="${installed##*k2oh.}" want="${wanted##*k2oh.}"
    if [[ "$have" =~ ^[0-9]+$ && "$want" =~ ^[0-9]+$ ]] && (( have > want )); then
        echo ahead
    else
        echo behind
    fi
}

row() { printf '    %-16s %-18s %s\n' "$1" "$2" "$3"; }

cmd_status() {
    load_manifest
    step "K2-OpenHost release ${REL[name]} (${REL[date]})"
    [[ -n "${REL[summary]}" ]] && info "${REL[summary]}"
    echo
    fetch_checkout "$KLIPPER_DIR"
    fetch_checkout "$T113_DIR"
    local rel installed
    rel="$(git_relation "$KLIPPER_DIR" "${REL[kalico_sha]}")"
    row "Kalico" "$(short_head "$KLIPPER_DIR")" "$(describe_relation "$rel") (${REL[kalico_sha]:0:8})"
    installed="$(mainsail_installed_tag)"
    rel="$(mainsail_relation "$installed" "${REL[mainsail_tag]}")"
    case "$rel" in
        same) row "Mainsail" "$installed" "on the release" ;;
        ahead) row "Mainsail" "$installed" "newer than the release (${REL[mainsail_tag]})" ;;
        behind) row "Mainsail" "$installed" "release: ${REL[mainsail_tag]}" ;;
        missing) row "Mainsail" "-" "no release_info.json in $MAINSAIL_DIR (release: ${REL[mainsail_tag]})" ;;
    esac
    rel="$(git_relation "$HELPER_REPO_DIR" "${REL[helper_sha]}")"
    row "Installer helper" "$(short_head "$HELPER_REPO_DIR")" "$(describe_relation "$rel") (${REL[helper_version]:-?})"
    rel="$(git_relation "$T113_DIR" "${REL[t113_bootstrap_sha]}")"
    row "T113 bootstrap" "$(short_head "$T113_DIR")" "$(describe_relation "$rel") (${REL[t113_bootstrap_version]:-?})"
    info "the T113 bootstrap row is this host's checkout: 'helper.sh t113 update' shows what slot B runs"
    local key printed=0
    for key in "${!REL[@]}"; do
        [[ "$key" == tested_* ]] || continue
        (( printed )) || { echo; info "Tested with:"; printed=1; }
        info "  ${key#tested_}: ${REL[$key]}"
    done
}

heaters_off() {
    # True when Klipper answers and every heater target is 0.
    curl -fsS --max-time 3 "$MOONRAKER_URL/printer/objects/query?heaters" 2>/dev/null \
        | python3 -c '
import json, sys, urllib.request
names = json.load(sys.stdin)["result"]["status"]["heaters"]["available_heaters"]
url = sys.argv[1] + "/printer/objects/query?" + "&".join(
    urllib.request.quote(name) + "=target" for name in names)
status = json.load(urllib.request.urlopen(url, timeout=3))["result"]["status"]
sys.exit(0 if all(not status[n].get("target") for n in names) else 1)
' "$MOONRAKER_URL" 2>/dev/null
}

apply_kalico() {
    # Returns 0 when the checkout moved.
    local sha="${REL[kalico_sha]}" branch="${REL[kalico_branch]}" rel current
    fetch_checkout "$KLIPPER_DIR"
    rel="$(git_relation "$KLIPPER_DIR" "$sha")"
    case "$rel" in
        same) ok "Kalico is on the release (${sha:0:8})"; return 1 ;;
        ahead*) info "Kalico is $(describe_relation "$rel"): left as it is"; return 1 ;;
        behind*) ;;
        *) warn "Kalico: $(describe_relation "$rel"): left as it is"; return 1 ;;
    esac
    current="$(git -C "$KLIPPER_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")"
    if [[ "$current" != "$branch" ]]; then
        warn "Kalico is on $current, the release is on $branch: left as it is"
        return 1
    fi
    if ! git -C "$KLIPPER_DIR" diff --quiet || ! git -C "$KLIPPER_DIR" diff --cached --quiet; then
        warn "$KLIPPER_DIR has local changes: left as it is"
        return 1
    fi
    info "Kalico: ${rel#behind } new commit(s):"
    git -C "$KLIPPER_DIR" log --oneline --no-decorate -n 10 "HEAD..$sha" | sed 's/^/      /'
    confirm "Bring Kalico to ${sha:0:8}?" y || { info "Kalico not changed"; return 1; }
    # Called as an if condition, where set -e does not stop on errors.
    git -C "$KLIPPER_DIR" merge -q --ff-only "$sha" || die "Kalico cannot fast-forward to ${sha:0:8}"
    "$KLIPPY_ENV/bin/pip" install -q -r "$KLIPPER_DIR/scripts/klippy-requirements.txt"         || die "the Klippy requirements did not install: Klipper was not restarted"
    refresh_cartographer_loader
    ok "Kalico at $(short_head "$KLIPPER_DIR")"
}

apply_mainsail() {
    local tag="${REL[mainsail_tag]}" installed rel
    installed="$(mainsail_installed_tag)"
    rel="$(mainsail_relation "$installed" "$tag")"
    case "$rel" in
        same) ok "Mainsail is on the release ($tag)"; return 0 ;;
        ahead) info "Mainsail $installed is newer than the release ($tag): left as it is"; return 0 ;;
    esac
    confirm "Install Mainsail $tag (now ${installed:-unknown})?" y || { info "Mainsail not changed"; return 0; }
    run_mainsail_update "$tag"
}

run_mainsail_update() { MAINSAIL_RELEASE_TAG="$1" bash "$SCRIPTS_DIR/mainsail.sh" update; }
run_t113_update() { K2OH_T113_REF="$1" bash "$SCRIPTS_DIR/t113.sh" update; }

restart_klipper_if_idle() {
    if klipper_is_printing; then
        warn "a print started: restart Klipper yourself when the printer is idle"
        return 0
    fi
    if ! heaters_off; then
        warn "a heater is on (or Klipper does not answer): restart Klipper yourself once the heaters are off"
        return 0
    fi
    confirm "Restart Klipper now to load the new Kalico?" n \
        || { info "restart Klipper later to load it (the old code keeps running until then)"; return 0; }
    restart_service klipper
}

cmd_apply() {
    local t113=0 arg
    for arg in "$@"; do
        case "$arg" in
            --t113) t113=1 ;;
            *) die "usage: $0 apply [--t113]" ;;
        esac
    done
    load_manifest
    step "Applying K2-OpenHost release ${REL[name]} (${REL[date]})"
    guard_not_printing
    if apply_kalico; then
        restart_klipper_if_idle
    fi
    apply_mainsail
    local rel
    rel="$(git_relation "$HELPER_REPO_DIR" "${REL[helper_sha]}")"
    if [[ "$rel" == behind* ]]; then
        warn "the installer helper is $(describe_relation "$rel"): restart it and accept its update (or git pull in $HELPER_REPO_DIR)"
    fi
    if (( t113 )); then
        run_t113_update "${REL[t113_bootstrap_sha]}"
    else
        info "T113 programs: not touched ('$0 apply --t113' or 'helper.sh t113 update')"
    fi
}

if [[ "${K2OH_RELEASE_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-status}" in
    status) cmd_status ;;
    apply) cmd_apply "${@:2}" ;;
    *) die "usage: $0 status | apply [--t113]" ;;
esac
