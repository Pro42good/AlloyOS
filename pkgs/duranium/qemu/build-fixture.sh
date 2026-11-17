#!/bin/sh
# Build the deterministic Duranium QEMU fixture.
#
# Everything that needs Linux filesystem tools runs inside an Alpine aarch64
# container. The host only needs Docker and QEMU.

set -eu
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
REPO=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT="$PKG_DIR/qemu/out"
BASELINE=${DURANIUM_BASELINE:-"$REPO/devices/kukui-krane/baselines/1000"}

mkdir -p "$OUT"

if ! command -v docker >/dev/null 2>&1; then
    printf 'build-fixture: Docker is required for ext4/FAT/GPT image construction\n' >&2
    exit 1
fi

set -- docker run --rm --platform linux/arm64 \
    -v "$PKG_DIR:/src:ro" \
    -v "$OUT:/out" \
    -e PROFILE="${DURANIUM_FIXTURE_PROFILE:-prod}"

if [ -r "$BASELINE/alloy-1001-floor.qcow2" ]; then
    set -- "$@" -v "$BASELINE:/baseline:ro"
else
    printf 'build-fixture: warning: baseline image not found at %s\n' "$BASELINE" >&2
    printf 'build-fixture: set DURANIUM_BASELINE to the directory containing alloy-1001-floor.qcow2,\n' >&2
    printf 'build-fixture: or set DURANIUM_KERNEL and DURANIUM_EFI_BOOT\n' >&2
fi

if [ -n "${DURANIUM_KERNEL:-}" ]; then
    [ -r "$DURANIUM_KERNEL" ] || { printf 'build-fixture: kernel not found: %s\n' "$DURANIUM_KERNEL" >&2; exit 1; }
    set -- "$@" -v "$DURANIUM_KERNEL:/in/vmlinuz:ro" -e DURANIUM_KERNEL=/in/vmlinuz
fi
if [ -n "${DURANIUM_EFI_BOOT:-}" ]; then
    [ -r "$DURANIUM_EFI_BOOT" ] || { printf 'build-fixture: EFI boot binary not found: %s\n' "$DURANIUM_EFI_BOOT" >&2; exit 1; }
    set -- "$@" -v "$DURANIUM_EFI_BOOT:/in/BOOTAA64.EFI:ro" -e DURANIUM_EFI_BOOT=/in/BOOTAA64.EFI
fi

set -- "$@" alpine:3.20 sh /src/qemu/build-in-container.sh
"$@"
