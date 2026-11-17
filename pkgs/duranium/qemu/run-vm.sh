#!/bin/sh
# Run one QEMU boot of the Duranium fixture.
#
# Usage:
#   run-vm.sh --disk IMG [--testdata IMG] [--log FILE] [--vars FILE]
#             [--timeout SECONDS] [--memory MB]
#
# Exit codes: 0 QEMU exited, 124 timed out and was killed.

set -u

DISK=""
TESTDATA=""
LOG=""
VARS=""
TIMEOUT=60
MEMORY=1024

while [ "$#" -gt 0 ]; do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --testdata) TESTDATA=$2; shift 2 ;;
        --log) LOG=$2; shift 2 ;;
        --vars) VARS=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        --memory) MEMORY=$2; shift 2 ;;
        *) printf 'run-vm: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$DISK" ] && [ -r "$DISK" ] || { printf 'run-vm: --disk is required\n' >&2; exit 2; }
[ -n "$LOG" ] || LOG=/tmp/duranium-qemu.log
mkdir -p "$(dirname "$LOG")"

QEMU=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
command -v "$QEMU" >/dev/null 2>&1 || { printf 'run-vm: %s not found\n' "$QEMU" >&2; exit 2; }

EDK2=${DURANIUM_EDK2_CODE:-}
if [ -z "$EDK2" ]; then
    for _c in /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
              /usr/share/qemu/edk2-aarch64-code.fd \
              /usr/share/AAVMF/AAVMF_CODE.fd; do
        [ -r "$_c" ] && { EDK2=$_c; break; }
    done
fi
[ -n "$EDK2" ] && [ -r "$EDK2" ] || { printf 'run-vm: EDK2 aarch64 firmware not found\n' >&2; exit 2; }

if [ -z "$VARS" ]; then
    VARS=$(mktemp "${TMPDIR:-/tmp}/duranium-vars.XXXXXX")
fi
if [ ! -s "$VARS" ]; then
    dd if=/dev/zero of="$VARS" bs=1m count=64 status=none
fi

ACCEL_ARGS="-accel hvf -cpu host"
case "$(uname -s)" in
    Linux)
        if [ -w /dev/kvm ]; then
            ACCEL_ARGS="-accel kvm -cpu host"
        else
            ACCEL_ARGS="-accel tcg -cpu cortex-a72"
        fi
        ;;
    Darwin) ACCEL_ARGS="-accel hvf -cpu host" ;;
esac

DISK_ARGS="-drive if=none,id=sys,file=$DISK,format=raw,cache=writethrough -device virtio-blk-pci,drive=sys"
if [ -n "$TESTDATA" ]; then
    [ -r "$TESTDATA" ] || { printf 'run-vm: testdata not found: %s\n' "$TESTDATA" >&2; exit 2; }
    DISK_ARGS="$DISK_ARGS -drive if=none,id=testdata,file=$TESTDATA,format=raw,readonly=on -device virtio-blk-pci,drive=testdata"
fi

# shellcheck disable=SC2086
"$QEMU" \
    -M virt,highmem=on $ACCEL_ARGS -smp 2 -m "$MEMORY" \
    -drive if=pflash,format=raw,readonly=on,file="$EDK2" \
    -drive if=pflash,format=raw,file="$VARS" \
    $DISK_ARGS \
    -display none -serial file:"$LOG" -monitor none -no-reboot &
PID=$!

START=$(date +%s)
RC=0
while kill -0 "$PID" 2>/dev/null; do
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        RC=124
        break
    fi
    sleep 1
done
if [ "$RC" -eq 0 ]; then
    wait "$PID" 2>/dev/null || RC=$?
fi
exit "$RC"
