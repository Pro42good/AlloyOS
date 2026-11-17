#!/bin/sh
# Visual shell for the ALLOY floor: cocoa window (virtio-gpu framebuffer)
# showing the real boot chain -> tty1 console login. Serial logged for evidence.
# Usage: run-alloy-gui.sh [img] [ssh_port]   (caller detaches with nohup)
# NOTE: frozen artifacts (uchg) cannot be opened read-write — boot a sandbox
# overlay (default) or pass an explicit overlay/profile path.
set -eu
# SECURITY_AUDIT2 LOW-2: numeric port only (netdev strings split on commas)
case "${PORT:-2222}" in *[!0-9]*|"") echo "bad PORT"; exit 2 ;; esac
[ "${PORT:-2222}" -ge 1 ] && [ "${PORT:-2222}" -le 65535 ] || { echo "PORT out of range"; exit 2; }
cd "$(dirname "$0")/.."
IMG="${1:-baselines/0007/sandbox.qcow2}"
if [ ! -f "$IMG" ]; then
  qemu-img create -f qcow2 -F qcow2 \
      -b "$(pwd)/baselines/0007/alloy-baseline-0007.qcow2" "$IMG" >/dev/null
fi
PORT="${2:-2222}"
SERIAL="baselines/0007/serial-gui.log"
VARS="baselines/0007/vars.fd"
CODE_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"

exec qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$CODE_FW" \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive if=none,id=system,file="$IMG",format=qcow2,discard=unmap \
  -device virtio-blk-pci,drive=system \
  -device virtio-gpu-pci \
  -display cocoa \
  -chardev socket,id=ser0,host=127.0.0.1,port=4445,server=on,wait=off,logfile="$SERIAL" \
  -serial chardev:ser0 \
  -monitor none \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
  -device virtio-net-pci,netdev=net0
