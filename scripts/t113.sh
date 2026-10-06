#!/usr/bin/env bash
# K2-OpenHost T113 bootstrap, driven from this host over SSH.
#   check         read-only compatibility check of the printer (writes nothing)
#   install       build the slot B system and write it to the printer
#   status        slot, setup and HelixScreen state on the printer
#   boot-b        trial boot of slot B (a power cycle returns to slot A)
#   commit        keep slot B (run while slot B is running)
#   boot-a        boot slot A again
#   host [IP]     change the external host address used by slot B
#   mcu-fw ARGS   run k2oh-mcu-fw on the printer (update, list, status, ...);
#                 custom --cfs-image paths are local CM5 files and are uploaded
#                 to the T113 after SHA-256 verification
#   link          connect this host to k2oh-ctl on the printer: token,
#                 [k2_t113] host, Moonraker power device for the MCU rail
#
# Slot A (the printer's current system) is never written. Slot B is built on
# this host from Creality's own OTA image (downloaded from Creality's CDN),
# so no Creality files are redistributed. The bootstrap itself comes from
# https://github.com/MzTechnology97/k2-openhost-t113-bootstrap, cloned to
# ~/k2-openhost-t113-bootstrap. Prepared and tested on stock 1.1.0.94; on other
# releases the bootstrap and the T113 USB gadget (OTG) mode are not guaranteed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The printer-side bootstrap lives in its own repository.
T113_REPO="${K2OH_T113_REPO:-https://github.com/MzTechnology97/k2-openhost-t113-bootstrap.git}"
T113_BRANCH="${K2OH_T113_BRANCH:-main}"
T113_DIR="${K2OH_T113_DIR:-${HOME}/k2-openhost-t113-bootstrap}"
WORK_DIR="${K2OH_T113_WORK:-${HOME}/k2oh-t113}"
T113_CONF="${STATE_DIR}/t113.conf"
SSH_SOCK="${STATE_DIR}/t113-ssh.sock"
KNOWN_HOSTS="${STATE_DIR}/t113_known_hosts"
# The work was prepared and tested on this stock release; others are allowed
# with a warning (bootstrap and T113 USB gadget mode not guaranteed).
TESTED_FIRMWARE="1.1.0.94"
# Only the K2 Pro is supported: Creality model F012 on board CR0CN200400C10.
K2_PRO_MODEL="F012"
K2_PRO_BOARD="CR0CN200400C10"
HELIX_REPO="prestonbrown/helixscreen"
REMOTE_DIR="/mnt/UDISK/k2oh-slotb"

T113_IP="${T113_IP:-}"
HOST_IP="${HOST_IP:-}"
[[ -f "$T113_CONF" ]] && source "$T113_CONF"

save_conf() {
    mkdir -p "$STATE_DIR"
    printf 'T113_IP=%q\nHOST_IP=%q\n' "$T113_IP" "$HOST_IP" > "$T113_CONF"
}

ask() {
    # ask "question" default -> echoes the answer
    local question="$1" default="${2:-}" answer
    if [[ "$ASSUME_YES" == "1" && -n "$default" ]]; then
        echo "$default"
        return
    fi
    printf '    %s [%s]: ' "$question" "$default" >&2
    read -r answer || answer=""
    echo "${answer:-$default}"
}

valid_address() { [[ "$1" =~ ^[0-9A-Za-z.-]+$ ]]; }

t113_ssh() {
    mkdir -p "$STATE_DIR"
    ssh -o ControlMaster=auto -o ControlPath="$SSH_SOCK" -o ControlPersist=15m \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "root@${T113_IP}" "$@"
}

t113_close() { ssh -o ControlPath="$SSH_SOCK" -O exit "root@${T113_IP}" 2>/dev/null || true; }

choose_addresses() {
    step "Printer and host addresses"
    T113_IP="$(ask "IP address of the K2 (its T113 board, on your network)" "$T113_IP")"
    valid_address "$T113_IP" || die "invalid printer address '$T113_IP'"
    local guess
    guess="$(ip -4 route get "$T113_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
    guess="${guess:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    HOST_IP="$(ask "IP address of this host as the printer sees it (Moonraker, HelixScreen)" "${HOST_IP:-$guess}")"
    valid_address "$HOST_IP" || die "invalid host address '$HOST_IP'"
    save_conf
    ok "printer ${T113_IP}, host ${HOST_IP} (saved in ${T113_CONF})"
}

connect() {
    [[ -n "$T113_IP" ]] || die "no printer address yet: run '$0 install' first"
    if ! t113_ssh true 2>/dev/null; then
        info "Log in to the printer as root. Stock password: creality_2024 (slot B always uses"
        info "the stock password; slot A uses yours if you changed it)."
        t113_ssh true || die "cannot reach root@${T113_IP} over SSH"
    fi
}

remote_facts() {
    # One read-only round trip: slot, boot environment, versions, free space.
    t113_ssh 'sh -s' <<'EOF'
case " $(cat /proc/cmdline) " in *" root=/dev/mmcblk0p6 "*) s=A ;; *" root=/dev/mmcblk0p7 "*) s=B ;; *) s="?" ;; esac
echo "slot=$s"
mkdir -p /var/lock
echo "env=$(fw_printenv -n boot_partition 2>/dev/null)/$(fw_printenv -n root_partition 2>/dev/null)"
echo "sys_version=$(sed -n 's/.*"sys_version":"\([^"]*\)".*/\1/p' /mnt/UDISK/creality/userdata/config/system_version.json 2>/dev/null)"
echo "board=$(fw_printenv -n board 2>/dev/null)"
echo "model=$(get_sn_mac.sh model 2>/dev/null)"
echo "sn_board=$(get_sn_mac.sh board 2>/dev/null)"
echo "kernel=$(uname -v)"
echo "udisk_free_kb=$(df -k /mnt/UDISK | awk 'NR==2 {print $4}')"
echo "k2oh=$([ -f /etc/k2openhost-release ] && sed -n 's/^version=//p' /etc/k2openhost-release)"
echo "slot_b=$([ "$(head -c 8 /dev/by-name/bootB 2>/dev/null)" = "ANDROID!" ] && [ "$(head -c 4 /dev/by-name/rootfsB 2>/dev/null)" = "hsqs" ] && echo image || echo empty)"
echo "k2oh_conf=$([ -f /mnt/UDISK/.k2openhost/k2openhost.conf ] && echo yes || echo no)"
EOF
}

fact() { sed -n "s/^$1=//p" <<<"$FACTS"; }

download_helix() {
    local out="$1" tag
    step "Downloading HelixScreen for the K2"
    tag="$(curl -fsSL "https://api.github.com/repos/${HELIX_REPO}/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" \
        || { warn "could not read the latest HelixScreen release; continuing without it"; return 0; }
    curl -fsSL -o "$out/helixscreen-k2-${tag}.tar.gz" \
        "https://github.com/${HELIX_REPO}/releases/download/${tag}/helixscreen-k2-${tag}.tar.gz" \
        && curl -fsSL -o "$out/helixscreen-install.sh" \
            "https://github.com/${HELIX_REPO}/releases/download/${tag}/install.sh" \
        || { warn "HelixScreen download failed; continuing without it"; rm -f "$out"/helixscreen-*; return 0; }
    ok "HelixScreen ${tag}"
}

upload() {
    local src="$1" name sum
    t113_ssh "mkdir -p '$REMOTE_DIR'"
    for path in "$src"/*; do
        name="$(basename "$path")"
        info "uploading ${name} ($(( $(stat -c %s "$path") / 1048576 )) MB)"
        t113_ssh "cat > '$REMOTE_DIR/$name'" < "$path"
        sum="$(t113_ssh "sha256sum '$REMOTE_DIR/$name'" | cut -d' ' -f1)"
        [[ "$sum" == "$(sha256sum "$path" | cut -d' ' -f1)" ]] || die "upload of $name is corrupted"
    done
    ok "files on the printer in ${REMOTE_DIR}"
}

wait_for_printer() {
    local i
    t113_close
    info "waiting for the printer to come back (up to 4 minutes)..."
    sleep 20
    for i in $(seq 1 44); do
        if timeout 3 bash -c "</dev/tcp/${T113_IP}/22" 2>/dev/null; then
            sleep 5
            connect
            return 0
        fi
        sleep 5
    done
    return 1
}

check_printer() {
    # Read-only checks shared by 'check' and 'install'. Prints the findings;
    # returns non-zero when the install must not continue.
    local problems=0
    step "Checking the printer (read-only)"
    FACTS="$(remote_facts)"
    info "model: $(fact model), board: $(fact board) / $(fact sn_board)"
    info "running slot: $(fact slot), next boot: $(fact env)"
    info "slot A firmware: $(fact sys_version)"
    info "UDISK free: $(( $(fact udisk_free_kb) / 1024 )) MB"
    if [[ "$(fact model)" == "$K2_PRO_MODEL" && "$(fact board)" == "$K2_PRO_BOARD" && "$(fact sn_board)" == "$K2_PRO_BOARD" ]]; then
        ok "Creality K2 Pro confirmed"
    else
        fail "not a Creality K2 Pro (needs model $K2_PRO_MODEL, board $K2_PRO_BOARD)"; problems=1
    fi
    if [[ "$(fact slot)" == "A" && "$(fact env)" == "bootA/rootfsA" ]]; then
        ok "slot A is running and boots by default"
    elif [[ "$(fact slot)" == "B" ]]; then
        warn "slot B is running (K2-OpenHost $(fact k2oh)); the install runs from slot A"; problems=1
    else
        fail "the boot environment does not point at the running slot A"; problems=1
    fi
    if (( $(fact udisk_free_kb) > 1500000 )); then
        ok "enough free space on UDISK"
    else
        fail "UDISK needs about 1.5 GB free"; problems=1
    fi
    if [[ "$(fact sys_version)" == "$TESTED_FIRMWARE" ]]; then
        ok "slot A runs $TESTED_FIRMWARE, the firmware this work was tested on"
    else
        warn "slot A runs $(fact sys_version): tested only on $TESTED_FIRMWARE; the bootstrap and"
        warn "the T113 USB gadget (OTG) mode are not guaranteed on other firmware"
    fi
    if [[ "$(fact slot_b)" == image ]]; then
        info "slot B already holds a system image (for example from an earlier Creality update):"
        info "the install saves it to /mnt/UDISK/.k2openhost/backup before replacing it"
    else
        info "slot B is empty"
    fi
    [[ "$(fact k2oh_conf)" == yes ]] && info "a K2-OpenHost setup is already on UDISK (it is kept)"
    true
    return "$problems"
}

proposed_base_version() {
    # Prints the release slot B would be built from (slot A's, else latest).
    local releases
    releases="$(python3 "$T113_DIR/fetch-stock-ota.py" --list --board "$(fact board)")" || return 1
    if grep -qx "$(fact sys_version)" <<<"$releases"; then
        fact sys_version
    else
        tail -n1 <<<"$releases"
    fi
}

cmd_check() {
    step "Getting the T113 bootstrap"
    apt_install git
    clone_or_update "$T113_REPO" "$T113_DIR" "$T113_BRANCH"
    ok "$(git -C "$T113_DIR" log -1 --format="%h %s")"
    choose_addresses
    connect
    local status=0
    check_printer || status=1
    step "Creality firmware for slot B"
    local proposed latest
    latest="$(python3 "$T113_DIR/fetch-stock-ota.py" --list --board "$(fact board)" | tail -n1)" \
        || die "cannot read Creality's firmware index"
    proposed="$(proposed_base_version)"
    info "latest Creality release: $latest"
    info "slot B would be built from: $proposed"
    if [[ "$proposed" == "$TESTED_FIRMWARE" ]]; then
        ok "the tested release"
    else
        warn "not the tested $TESTED_FIRMWARE: the install asks for confirmation"
    fi
    step "Result"
    if (( status == 0 )); then
        ok "ready for the T113 bootstrap; nothing was changed on the printer"
        info "Next: ./helper.sh t113 install (menu 24)"
    else
        fail "not ready; see the messages above. Nothing was changed on the printer."
        return 1
    fi
}

choose_base_version() {
    # Slot B is built from the release slot A runs, so both slots carry the
    # same MCU firmware files; the latest release is offered when slot A's is
    # not in Creality's index.
    local slot_a latest releases
    slot_a="$(fact sys_version)"
    releases="$(python3 "$T113_DIR/fetch-stock-ota.py" --list --board "$(fact board)")" \
        || die "cannot read Creality's firmware index"
    latest="$(tail -n1 <<<"$releases")"
    if grep -qx "$slot_a" <<<"$releases"; then
        BASE_VERSION="$slot_a"
    else
        warn "slot A's release ($slot_a) is not in Creality's index; the latest is $latest"
        BASE_VERSION="$latest"
    fi
    BASE_VERSION="$(ask "Creality firmware release to build slot B from (latest: $latest)" "$BASE_VERSION")"
    grep -qx "$BASE_VERSION" <<<"$releases" || die "release $BASE_VERSION is not in Creality's index"
    if [[ "$BASE_VERSION" != "$TESTED_FIRMWARE" ]]; then
        warn "This work was prepared and tested on firmware $TESTED_FIRMWARE only."
        warn "On $BASE_VERSION the bootstrap and the T113 USB gadget (OTG) mode are NOT guaranteed."
        confirm "Continue with $BASE_VERSION anyway?" n || die "stopped"
    fi
    if [[ "$BASE_VERSION" != "$slot_a" ]]; then
        warn "Slot A ($slot_a) and slot B ($BASE_VERSION) carry different MCU firmware files:"
        warn "each slot reflashes the boards to its own files when it boots."
    fi
}

cmd_install() {
    cat <<EOF

    This writes a K2-OpenHost system to slot B of the printer's T113 board.
    Slot A, the system the printer runs now, is not modified: it stays
    available as a fallback with 'k2oh-slot boot-a' or a power cycle during
    the trial boot. MCU firmware is not touched; updating it is a separate,
    manual step (k2oh-mcu-fw).

    Experienced users only. Read the disclaimer first:
    https://github.com/MzTechnology97/K2-OpenHost/blob/main/docs/en/DISCLAIMER.md
EOF
    confirm "Continue?" n || return 0
    step "Getting the T113 bootstrap"
    apt_install git
    clone_or_update "$T113_REPO" "$T113_DIR" "$T113_BRANCH"
    ok "$(git -C "$T113_DIR" log -1 --format="%h %s")"
    choose_addresses
    connect

    check_printer || die "the printer is not ready for the bootstrap; nothing was changed"
    choose_base_version

    step "Preparing the build tools"
    require_sudo
    apt_install fakeroot squashfs-tools curl python3
    mkdir -p "$WORK_DIR"

    local stock="$WORK_DIR/stock-$BASE_VERSION"
    step "Downloading the stock Creality firmware $BASE_VERSION"
    if [[ -f "$stock/kernel" && -f "$stock/rootfs" ]]; then
        ok "already downloaded"
    else
        python3 "$T113_DIR/fetch-stock-ota.py" "$BASE_VERSION" "$stock" --board "$(fact board)"
    fi

    step "Building the slot B system"
    rm -rf "$WORK_DIR/out"
    bash "$T113_DIR/build-slot-b.sh" --kernel "$stock/kernel" --rootfs "$stock/rootfs" \
        --base-version "$BASE_VERSION" --out "$WORK_DIR/out"
    if confirm "Install HelixScreen on the printer screen (recommended)?" y; then
        download_helix "$WORK_DIR/out"
    fi

    step "Copying slot B to the printer"
    upload "$WORK_DIR/out"

    step "Checking on the printer"
    t113_ssh "cd '$REMOTE_DIR' && sh install-slot-b.sh --check --host '$HOST_IP'"
    confirm "Write slot B now? Slot A stays untouched." n || { info "nothing written; rerun to continue"; return 0; }
    step "Writing slot B"
    t113_ssh "cd '$REMOTE_DIR' && sh install-slot-b.sh --host '$HOST_IP'"
    t113_ssh "rm -rf '$REMOTE_DIR'"

    step "Next: trial boot of slot B"
    info "Connect the printer's service Micro-USB port to this host."
    info "During the trial boot the screen shows only the boot logo until HelixScreen starts"
    info "(first boot installs it, about a minute). If slot B does not come up, power cycle"
    info "the printer: it returns to slot A."
    if confirm "Link this host to the T113 control service now (k2oh-ctl)?" y; then
        cmd_link
    else
        info "Later: $0 link"
    fi
    if confirm "Start the trial boot of slot B now?" n; then
        cmd_boot_b
    else
        info "Later: $0 boot-b"
    fi
}

cmd_link() {
    # Connects this host to k2oh-ctl, the control service of slot B. Safe to
    # run again: it rewrites the same files.
    connect
    local token cfg="${CONFIG_DIR}/k2_t113.cfg" tokfile="${CONFIG_DIR}/k2oh_t113.token"
    local mconf="${CONFIG_DIR}/moonraker_k2_t113.conf" pcfg="${CONFIG_DIR}/printer.cfg"
    step "Linking this host to the T113 control service (k2oh-ctl)"
    token="$(t113_ssh 'cat /mnt/UDISK/.k2openhost/ctl.token 2>/dev/null' | tr -d '\r\n ')"
    [[ "$token" =~ ^[A-Za-z0-9_-]{16,}$ ]] \
        || die "no k2oh-ctl token on the printer yet: install the T113 bootstrap first (menu 24)"
    (umask 077 && printf '%s\n' "$token" > "$tokfile")
    ok "token saved to $tokfile (readable only by you)"

    if [[ ! -f "$cfg" ]]; then
        [[ -f "${KLIPPER_DIR}/config/k2/k2_t113.cfg" ]] \
            || die "this Kalico has no config/k2/k2_t113.cfg yet: update Kalico, then run '$0 link' again"
        cp "${KLIPPER_DIR}/config/k2/k2_t113.cfg" "$cfg"
    fi
    sed -i "s|^host:.*|host: ${T113_IP}          # T113 address (set by the installer helper)|" "$cfg"
    ok "[k2_t113] host: ${T113_IP} in $(basename "$cfg")"

    (umask 077 && cat > "$mconf" <<EOF
# K2-OpenHost: the printer's MCU power rail (T113 GPIO140) as a Moonraker power
# device, through k2oh-ctl. Written by the installer helper ('t113 link').
# The T113 refuses "off" unless the print state is idle.
[power K2_MCU_Power]
type: http
on_url: http://${T113_IP}:7130/power/mcu
off_url: http://${T113_IP}:7130/power/mcu
status_url: http://${T113_IP}:7130/power/mcu
request_template:
  {% do http_request.set_method("POST") %}
  {% do http_request.add_header("X-K2OH-Token", "${token}") %}
  {% do http_request.add_header("Content-Type", "application/json") %}
  {% do http_request.set_body({"command": command}) %}
  {% do http_request.send() %}
response_template:
  {% set resp = http_request.last_response().json() %}
  {resp["state"]}
locked_while_printing: True
restart_klipper_when_powered: True
restart_delay: 3
EOF
)
    ok "Moonraker power device K2_MCU_Power in $(basename "$mconf")"
    if ! grep -q '^\[include moonraker_k2_t113.conf\]' "$(moonraker_conf)"; then
        backup_file "$(moonraker_conf)"
        printf '\n[include moonraker_k2_t113.conf]\n' >> "$(moonraker_conf)"
        ok "included from moonraker.conf"
    fi

    if [[ -f "${KLIPPER_DIR}/klippy/extras/k2_t113.py" ]]; then
        if grep -q '^#\[include k2_t113.cfg\]' "$pcfg"; then
            backup_file "$pcfg"
            sed -i 's|^#\[include k2_t113.cfg\]|[include k2_t113.cfg]|' "$pcfg"
        elif ! grep -q '^\[include k2_t113.cfg\]' "$pcfg"; then
            backup_file "$pcfg"
            sed -i 's|^\[include motor_control.cfg\]|&\n[include k2_t113.cfg]|' "$pcfg"
        fi
        ok "[include k2_t113.cfg] active in printer.cfg"
    else
        warn "this Kalico has no k2_t113 module yet: the include stays off."
        warn "Update Kalico, then run '$0 link' again."
    fi
    info "Restart Moonraker and Klipper to load the changes (menu 22)."
}

cmd_boot_b() {
    connect
    t113_ssh "/mnt/UDISK/.k2openhost/bin/k2oh-slot boot-b && { nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 & }"
    if wait_for_printer; then
        FACTS="$(remote_facts)"
        if [[ "$(fact slot)" == "B" ]]; then
            ok "slot B is running (K2-OpenHost $(fact k2oh))"
            t113_ssh "k2oh-setup status" || true
            info "Check that Klipper on this host connects (Mainsail), then keep slot B with:"
            info "  $0 commit"
        else
            warn "the printer came back on slot $(fact slot)"
        fi
    else
        warn "the printer did not answer; power cycle it to return to slot A"
    fi
}

cmd_commit() {
    connect
    t113_ssh "k2oh-slot commit"
}

cmd_boot_a() {
    connect
    confirm "Boot slot A at the next reboot and reboot now?" n || return 0
    t113_ssh "{ /mnt/UDISK/.k2openhost/bin/k2oh-slot boot-a || k2oh-slot boot-a; } && { nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 & }"
    wait_for_printer && ok "the printer is back" || warn "the printer did not answer yet"
}

cmd_status() {
    connect
    t113_ssh "k2oh-slot status 2>/dev/null || /mnt/UDISK/.k2openhost/bin/k2oh-slot status; [ -x /usr/sbin/k2oh-setup ] && k2oh-setup status; true"
}

cmd_host() {
    connect
    local ip="${1:-}"
    [[ -n "$ip" ]] || ip="$(ask "External host address for slot B" "$HOST_IP")"
    valid_address "$ip" || die "invalid address '$ip'"
    HOST_IP="$ip"
    save_conf
    t113_ssh "k2oh-setup --host '$ip'"
}

idle_print_state() {
    # Prints the Klipper print state when it is known and idle; fails
    # otherwise (printing, paused, or no answer: unknown is never idle).
    local state
    state="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null || true)"
    case "$state" in
        standby|complete|cancelled|error) echo "$state" ;;
        *) return 1 ;;
    esac
}

stop_klipper_for_flash() {
    local service state
    service="$(systemctl is-active klipper 2>/dev/null || true)"
    if [[ "$service" == "inactive" || "$service" == "failed" ]]; then
        ok "Klipper is stopped on this host"
        return
    fi
    state="$(idle_print_state)" \
        || die "Klipper is $service and its print state is not a known idle state: not stopping it"
    info "Klipper is $service, print state: $state"
    confirm "Stop Klipper on this host for the flash?" n || die "Klipper must be stopped before flashing"
    sudo systemctl stop klipper
    service="$(systemctl is-active klipper 2>/dev/null || true)"
    [[ "$service" == "inactive" || "$service" == "failed" ]] || die "Klipper did not stop (it is $service)"
    ok "Klipper stopped; start it again after the flash: sudo systemctl start klipper"
}

host_evidence() {
    # Proof for k2oh-mcu-fw that Klipper is stopped and no process on this
    # host holds the printer's gadget ports (needs root to see every process).
    sudo python3 "$T113_DIR/host/k2oh-host-evidence"
}

CUSTOM_CFS_REMOTE=""

stage_custom_cfs_image() {
    # The path supplied to the CM5 helper is local to the CM5. Upload a
    # hash-verified copy to persistent T113 storage, preserving the basename:
    # k2oh-mcu-fw derives the exact boot/app identity from that basename.
    local image="$1" expected="${2,,}" actual base remote_dir remote_tmp remote_sum
    [[ -f "$image" ]] || die "custom CFS image does not exist on this host: $image"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "--cfs-sha256 must be exactly 64 hexadecimal characters"
    actual="$(sha256sum "$image" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "custom CFS SHA-256 mismatch on this host: expected $expected, got $actual"

    base="$(basename "$image")"
    [[ "$base" =~ ^cfs[0-9]+_[0-9]+_G[0-9]+-cfs[0-9]+_[0-9]+_[0-9]+([-.][A-Za-z0-9_.-]+)?\.bin$ ]] \
        || die "custom CFS filename must encode exact boot and application identity"

    # Do not stop Klipper unless the printer-side bootstrap actually supports
    # the guarded same-version custom-image path.
    t113_ssh "k2oh-mcu-fw apply --help 2>&1 | grep -q -- '--cfs-image'" \
        || die "the installed T113 bootstrap does not support guarded custom CFS images"

    remote_dir="/mnt/UDISK/.k2openhost/custom-cfs-upload/${expected}"
    CUSTOM_CFS_REMOTE="${remote_dir}/${base}"
    remote_tmp="${CUSTOM_CFS_REMOTE}.tmp.$$"
    t113_ssh "mkdir -p '$remote_dir' && chmod 700 '$remote_dir' && rm -f '$remote_tmp'"
    info "uploading verified custom CFS image to the T113: $base"
    t113_ssh "cat > '$remote_tmp'" < "$image"
    remote_sum="$(t113_ssh "sha256sum '$remote_tmp'" | awk '{print $1}')"
    if [[ "$remote_sum" != "$expected" ]]; then
        t113_ssh "rm -f '$remote_tmp'" || true
        CUSTOM_CFS_REMOTE=""
        die "custom CFS upload is corrupted: expected $expected, got $remote_sum"
    fi
    t113_ssh "chmod 0400 '$remote_tmp' && mv -f '$remote_tmp' '$CUSTOM_CFS_REMOTE'"
    remote_sum="$(t113_ssh "sha256sum '$CUSTOM_CFS_REMOTE'" | awk '{print $1}')"
    if [[ "$remote_sum" != "$expected" ]]; then
        cleanup_custom_cfs_image
        die "custom CFS staged image changed after upload"
    fi
    ok "custom CFS image staged on the T113 with matching SHA-256"
}

cleanup_custom_cfs_image() {
    [[ -n "$CUSTOM_CFS_REMOTE" ]] || return 0
    local path="$CUSTOM_CFS_REMOTE" dir
    dir="${path%/*}"
    t113_ssh "rm -f '$path'; rmdir '$dir' 2>/dev/null || true" >/dev/null 2>&1 || true
    CUSTOM_CFS_REMOTE=""
}

cmd_mcu_fw() {
    local action="${1:-}" image="" expected="" a q remote_cmd rc=0
    local -a original=("$@") remote_args=()
    local i=0

    # Parse the two custom-image arguments before touching Klipper.  The path
    # is a CM5-local path; the SHA is an independent operator-provided value.
    while (( i < ${#original[@]} )); do
        a="${original[$i]}"
        case "$a" in
            --cfs-image)
                (( i + 1 < ${#original[@]} )) || die "--cfs-image requires a local file path"
                image="${original[$((i + 1))]}"
                i=$((i + 2))
                ;;
            --cfs-image=*)
                image="${a#--cfs-image=}"
                i=$((i + 1))
                ;;
            --cfs-sha256)
                (( i + 1 < ${#original[@]} )) || die "--cfs-sha256 requires a value"
                expected="${original[$((i + 1))]}"
                remote_args+=("$a" "$expected")
                i=$((i + 2))
                ;;
            --cfs-sha256=*)
                expected="${a#--cfs-sha256=}"
                remote_args+=("$a")
                i=$((i + 1))
                ;;
            *)
                remote_args+=("$a")
                i=$((i + 1))
                ;;
        esac
    done

    if [[ -n "$image" || -n "$expected" ]]; then
        [[ "$action" == "apply" ]] || die "--cfs-image/--cfs-sha256 are supported only with 'mcu-fw apply'"
        [[ -n "$image" && -n "$expected" ]] || die "custom CFS flashing requires both --cfs-image and --cfs-sha256"
        [[ " ${remote_args[*]} " == *" --cfs "* ]] || die "custom CFS flashing also requires --cfs"
    fi

    if [[ "$action" == "apply" || "$action" == "update" ]]; then
        clone_or_update "$T113_REPO" "$T113_DIR" "$T113_BRANCH"
        connect
        require_sudo
        if [[ -n "$image" ]]; then
            trap 'cleanup_custom_cfs_image' EXIT
            stage_custom_cfs_image "$image" "$expected"
            remote_args+=("--cfs-image" "$CUSTOM_CFS_REMOTE")
        fi
        # Image validation/upload and printer-side capability checks happen
        # before stopping Klipper.  From this point the bus must have one owner.
        stop_klipper_for_flash
        remote_args+=("--moonraker" "http://${HOST_IP}:7125" "--host-evidence" "$(host_evidence)")
    else
        connect
    fi

    remote_cmd="k2oh-mcu-fw"
    for a in "${remote_args[@]}"; do
        printf -v q '%q' "$a"
        remote_cmd+=" $q"
    done

    ssh -t -o ControlMaster=auto -o ControlPath="$SSH_SOCK" -o ControlPersist=15m \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        "root@${T113_IP}" "$remote_cmd" || rc=$?
    cleanup_custom_cfs_image
    trap - EXIT
    return "$rc"
}


if [[ "${K2OH_T113_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    check) cmd_check ;;
    install) cmd_install ;;
    status) cmd_status ;;
    boot-b) cmd_boot_b ;;
    commit) cmd_commit ;;
    boot-a) cmd_boot_a ;;
    host) cmd_host "${2:-}" ;;
    mcu-fw) shift; cmd_mcu_fw "$@" ;;
    link) cmd_link ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac