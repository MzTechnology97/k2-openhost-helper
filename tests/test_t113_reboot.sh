#!/usr/bin/env bash
# t113 boot-b/boot-a: the reboot really happens, a printer that did not
# reboot is not reported as back, no slot switch during a print, and the
# install leaves printer.cfg on names that work in both slots.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HELPER_DIR="$ROOT" K2OH_T113_LIB_ONLY=1
# the Klipper start gate of this machine, if any, stays untouched
export K2OH_GATE_DROPIN="$TMP/no-gate.conf"
mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$ROOT/scripts/t113.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

# No real waiting, port 22 always open, no real SSH session.
sleep() { :; }
timeout() { return 0; }
connect() { :; }
t113_close() { :; }
T113_IP=192.0.2.10

# 1. The boot id never changes: the printer did not reboot, not "back".
if (
    t113_ssh() { case "$*" in *boot_id*) echo old-boot ;; esac; }
    reboot_printer
) >/dev/null 2>&1; then
    fail_test "reported back although the boot id did not change"
fi

# 2. The reboot runs in the foreground and a new boot id is accepted.
(
    t113_ssh() {
        case "$*" in
            *boot_id*) [[ -f "$TMP/rebooted" ]] && echo new-boot || echo old-boot ;;
            *reboot*)
                [[ "$*" != *nohup* && "$*" != *"&"* ]] || fail_test "reboot started in the background: $*"
                touch "$TMP/rebooted" ;;
        esac
    }
    reboot_printer >/dev/null 2>&1 || fail_test "a new boot id was not accepted"
) || exit 1
[[ -f "$TMP/rebooted" ]] || fail_test "no reboot command sent"

# 3. No slot switch while printing or paused; unknown state only warns.
# (not "state": guard_slot_switch has a local of that name)
for print_state in printing paused; do
    if (
        curl() { echo "{\"result\":{\"status\":{\"print_stats\":{\"state\":\"$print_state\"}}}}"; }
        guard_slot_switch
    ) >/dev/null 2>&1; then
        fail_test "slot switch allowed while $print_state"
    fi
done
(
    curl() { return 7; }
    guard_slot_switch
) >/dev/null 2>&1 || fail_test "an unknown print state must not block"

# 4. After the install, printer.cfg uses the udev names of both slots.
mkdir -p "$HOME/printer_data/config"
cat > "$HOME/printer_data/config/printer.cfg" <<'EOF'
[serial_485 serial485]
serial: /dev/serial/by-id/usb-Allwinner_Technology_Inc._Gadget_Serial-if02-port0
baud: 230400

[mcu]
serial: /dev/serial/by-id/usb-Allwinner_Technology_Inc._Gadget_Serial-if00-port0

[mcu nozzle_mcu]
serial: /dev/serial/by-id/usb-Allwinner_Technology_Inc._Gadget_Serial-if01-port0
EOF
(
    sudo_render() { :; }
    sudo() { :; }
    use_udev_serial_names >/dev/null 2>&1
) || fail_test "use_udev_serial_names failed"
cfg="$HOME/printer_data/config/printer.cfg"
grep -q '^serial: /dev/k2-main$' "$cfg" || fail_test "[mcu] not on /dev/k2-main"
grep -q '^serial: /dev/k2-nozzle$' "$cfg" || fail_test "[mcu nozzle_mcu] not on /dev/k2-nozzle"
grep -q '^serial: /dev/k2-rs485$' "$cfg" || fail_test "[serial_485] not on /dev/k2-rs485"
! grep -q Allwinner "$cfg" || fail_test "a by-id name is left"

echo "t113 reboot and serial name tests: PASS"
