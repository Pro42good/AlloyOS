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

MOUNT_ARGS="-v $PKG_DIR:/src:ro -v $OUT:/out"
if [ -r "$BASELINE/alloy-1001-floor.qcow2" ]; then
    MOUNT_ARGS="$MOUNT_ARGS -v $BASELINE:/baseline:ro"
else
    printf 'build-fixture: warning: baseline image not found at %s\n' "$BASELINE" >&2
    printf 'build-fixture: set DURANIUM_BASELINE to the directory containing alloy-1001-floor.qcow2\n' >&2
fi

# shellcheck disable=SC2086
docker run --rm --platform linux/arm64 $MOUNT_ARGS \
    -e PROFILE="${DURANIUM_FIXTURE_PROFILE:-prod}" \
    alpine:3.20 sh /src/qemu/build-in-container.sh
