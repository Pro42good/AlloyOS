#!/bin/sh
# Headless QEMU boot for measured ALLOY baseline runs.
# Mirrors scripts/run-pmos-vm.sh headless mode (same geometry/devices) plus:
#   -daemonize -pidfile (for scripted timing) and per-run serial logfile.
#
# Usage: run-qemu-headless.sh <img.qcow2> <serial.log> <pidfile> [ssh_port] [vars.fd]
set -eu
# SECURITY_AUDIT2 LOW-2: numeric port only (netdev strings split on commas)
case "${PORT:-2222}" in *[!0-9]*|"") echo "bad PORT"; exit 2 ;; esac
[ "${PORT:-2222}" -ge 1 ] && [ "${PORT:-2222}" -le 65535 ] || { echo "PORT out of range"; exit 2; }

IMG="$1"; SERIAL="$2"; PIDF="$3"; PORT="${4:-2222}"; VARS="${5:-images/firmware/vars-pmos.fd}"
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
  -display none \
  -chardev socket,id=ser0,host=127.0.0.1,port=4445,server=on,wait=off,logfile="$SERIAL" \
  -serial chardev:ser0 \
  -monitor none \
  -daemonize \
  -pidfile "$PIDF" \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
  -device virtio-net-pci,netdev=net0
