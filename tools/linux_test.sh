#!/bin/bash
# Host-side test for the nrf-usb-hci firmware on a Linux machine (e.g. Arduino UNO Q).
#
#   ./linux_test.sh                 USB enumeration + BLE controller + SMP image state
#   ./linux_test.sh update <dir>    Update both cores from <dir> (netcore first, then app)
#
# <dir> must contain:
#   app.signed.bin   (build/<app>/zephyr/zephyr.signed.bin)
#   net.signed.bin   (build/signed_by_mcuboot_and_b0_hci_ipc.bin)
#
# Requires: bluez (btmgmt, hciconfig), smpmgr (pip install smpmgr) in ./.venv
set -u
cd "$(dirname "$0")"
[ -f .venv/bin/activate ] && . .venv/bin/activate

VIDPID=2fe3:000b

find_tty() {
    local t
    t=$(ls /dev/serial/by-id/*Zephyr*BT_HCI* 2>/dev/null | head -1)
    [ -z "$t" ] && t=$(ls /dev/serial/by-id/usb-*2fe3* 2>/dev/null | head -1)
    [ -z "$t" ] && t=/dev/ttyACM0
    echo "$t"
}

wait_usb() {
    for _ in $(seq 1 60); do
        lsusb -d "$VIDPID" >/dev/null 2>&1 && [ -e "$(find_tty)" ] && return 0
        sleep 1
    done
    return 1
}

echo "== USB"
if ! lsusb -d "$VIDPID"; then
    echo "Device $VIDPID not enumerated. Last kernel USB messages:"
    journalctl -k -n 15 --no-pager | grep -i usb
    exit 1
fi

HCI=""
for h in /sys/class/bluetooth/hci*; do
    readlink -f "$h/device" | grep -q usb && HCI=$(basename "$h")
done
echo "== BLE controller: ${HCI:-not found}"
if [ -n "$HCI" ]; then
    hciconfig -a "$HCI" | head -5
    echo "-- LE scan (8 s) on $HCI"
    timeout 10 btmgmt --index "${HCI#hci}" find -l 2>&1 | grep -E "dev_found|name" | head -10
fi

TTY=$(find_tty)
echo "== SMP on $TTY"
smpmgr --port "$TTY" image state-read

if [ "${1:-}" = "update" ]; then
    DIR=${2:?usage: $0 update <dir>}
    NET="$DIR/net.signed.bin"; APP="$DIR/app.signed.bin"
    echo "== Upload network core (image 1)"
    smpmgr --port "$TTY" image upload "$NET" --slot 1 || exit 1
    echo "== Upload application core (image 0)"
    smpmgr --port "$TTY" image upload "$APP" --slot 0 || exit 1
    smpmgr --port "$TTY" image state-read
    echo "== Mark network core first, then application (NCSDK-34106)"
    for h in "$(python3 -c 'import sys;from smpclient.mcuboot import ImageInfo;print(ImageInfo.load_file(sys.argv[1]).get_tlv(0x10).value.hex())' "$NET")" \
             "$(python3 -c 'import sys;from smpclient.mcuboot import ImageInfo;print(ImageInfo.load_file(sys.argv[1]).get_tlv(0x10).value.hex())' "$APP")"; do
        smpmgr --port "$TTY" image state-write "$h" || exit 1
    done
    echo "== Reset"
    smpmgr --port "$TTY" os reset
    sleep 5
    wait_usb || { echo "Device did not come back"; exit 1; }
    TTY=$(find_tty)
    smpmgr --port "$TTY" image state-read
fi
