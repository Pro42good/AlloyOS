#!/bin/sh
# Boot the Krane-like postmarketOS ARM VM (qemu-aarch64 + Phosh) on Apple Silicon.
# Verified working: boots to login, SSH on localhost:2222, GUI via cocoa window.
#
# Usage:
#   ./run-pmos-vm.sh            # GUI window (Phosh desktop)
#   ./run-pmos-vm.sh headless   # no window, serial log to /tmp/pmos-serial.log
#   ./run-pmos-vm.sh serial     # GUI-less + interactive serial in terminal
#
# Login (console + SSH): user / 147147
# SSH:                   ssh -p 2222 user@localhost
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="${PMOS_IMG:-$SCRIPT_DIR/../images/pmos-qemu-aarch64.qcow2}"
BREW_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
VARS="$SCRIPT_DIR/../images/firmware/vars-pmos.fd"
MODE="${1:-gui}"

[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
[ -f "$VARS" ] || { dd if=/dev/zero of="$VARS" bs=1m count=64 status=none; }

# SSH is bound to loopback only (hostfwd tcp:127.0.0.1:...), never 0.0.0.0 —
# see SECURITY_AUDIT_2026-09-09.md HIGH-1.
set -- \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$BREW_FW" \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive if=none,id=system,file="$IMG",format=qcow2,discard=unmap \
  -device virtio-blk-pci,drive=system \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0

if [ "$MODE" = "gui" ]; then
  set -- "$@" -display cocoa -device virtio-gpu-pci
elif [ "$MODE" = "serial" ]; then
  set -- "$@" -nographic
else
  set -- "$@" -display none \
    -chardev socket,id=ser0,host=127.0.0.1,port=4445,server=on,wait=off,logfile=/tmp/pmos-serial.log \
    -serial chardev:ser0 \
    -monitor none
fi

exec qemu-system-aarch64 "$@"
