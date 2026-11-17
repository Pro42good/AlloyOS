#!/bin/sh
# DEPRECATED — superseded by scripts/run-pmos-vm.sh (gui|headless|serial).
# Kept only for reference; if you must run it, know that its defaults are
# pinned to loopback SSH and its firmware logic predates the final build
# pipeline. Prefer run-pmos-vm.sh in every case.
# Login: user / 147147
set -eu
IMG="${1:-$HOME/.local/var/pmbootstrap/chroot_native/home/pmos/rootfs/qemu-aarch64.img}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$SCRIPT_DIR/../images/firmware"

echo "==> QEMU: $(qemu-system-aarch64 --version | head -1)"
echo "==> IMG : $IMG"
echo "==> machine: virt, accel hvf:tcg, cpu host(max fallback cortex-a72)"
echo "==> NOTE: deprecated - prefer scripts/run-pmos-vm.sh"

BREW_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
UEFI_CODE="$FW_DIR/QEMU_EFI.fd"
if [ -f "$BREW_FW" ]; then
  VARS="$FW_DIR/vars-aarch64.fd"
  mkdir -p "$FW_DIR"
  if [ ! -f "$VARS" ]; then
    dd if=/dev/zero of="$VARS" bs=1m count=64 status=none
  fi
  set -- \
    -drive if=pflash,format=raw,readonly=on,file="$BREW_FW" \
    -drive if=pflash,format=raw,file="$VARS"
elif [ -f "$UEFI_CODE" ]; then
  set -- -drive if=pflash,format=raw,readonly=on,file="$UEFI_CODE"
else
  echo "NOTE: no UEFI firmware found - trying direct -kernel boot if boot/ files exist."
  set --
fi

# SSH bound to loopback only (SECURITY_AUDIT HIGH-1).
exec qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -device virtio-gpu-pci \
  -display cocoa \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -drive if=none,id=system,file="$IMG",format=qcow2,discard=unmap,detect-zeroes=unmap \
  -device virtio-blk-pci,drive=system \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  "$@"
