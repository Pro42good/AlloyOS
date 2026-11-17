#!/bin/sh
# EDK2 firmware check for qemu-system-aarch64 -M virt on macOS.
# Homebrew QEMU already ships it — no download needed.
set -eu
BREW_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
if [ -f "$BREW_FW" ]; then
  echo "==> OK: $BREW_FW"
  ls -lh "$BREW_FW"
  echo "run-qemu-arm.sh uses it as pflash code + auto-creates images/firmware/vars-aarch64.fd"
else
  echo "MISSING: $BREW_FW — reinstall qemu: brew reinstall qemu"
  exit 1
fi
