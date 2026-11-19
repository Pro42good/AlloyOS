#!/bin/sh
# Run one QEMU boot of the Duranium fixture.
#
# Usage:
#   run-vm.sh --disk IMG [--testdata IMG] [--log FILE] [--vars FILE]
#             [--timeout SECONDS] [--memory MB] [--interactive]
#             [--in-container]
#
# Exit codes: 0 QEMU exited, 124 timed out and was killed.
#
# Container mode (DURANIUM_QEMU_IN_CONTAINER=1 or --in-container) runs QEMU
# inside an Alpine container with TCG. It is much slower than native
# acceleration, but the guest's block device view is served by a Linux page
# cache. This matters on macOS: with hvf and a host APFS file, a disk that is
# written in place across QEMU boots has been observed to serve stale content
# for individual blocks to a later boot while the host file itself is
# byte-correct. The QEMU suite defaults to container mode for this reason.

set -u

DISK=""
TESTDATA=""
LOG=""
VARS=""
TIMEOUT=60
MEMORY=1024
INTERACTIVE=0
CONTMODE=${DURANIUM_QEMU_IN_CONTAINER:-0}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --testdata) TESTDATA=$2; shift 2 ;;
        --log) LOG=$2; shift 2 ;;
        --vars) VARS=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        --memory) MEMORY=$2; shift 2 ;;
        --interactive) INTERACTIVE=1; shift ;;
        --in-container) CONTMODE=1; shift ;;
        *) printf 'run-vm: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$DISK" ] || { printf 'run-vm: --disk is required\n' >&2; exit 2; }
if [ "$CONTMODE" = "1" ]; then
    # The disk lives on VM-local storage (docker volume); the host path is
    # only a label.
    :
else
    [ -r "$DISK" ] || { printf 'run-vm: --disk is required and must be readable\n' >&2; exit 2; }
fi
[ -n "$LOG" ] || LOG=/tmp/duranium-qemu.log
mkdir -p "$(dirname "$LOG")"

EDK2=${DURANIUM_EDK2_CODE:-}
if [ -z "$EDK2" ]; then
    for _c in /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
              /usr/share/qemu/edk2-aarch64-code.fd \
              /usr/share/AAVMF/AAVMF_CODE.fd; do
        [ -r "$_c" ] && { EDK2=$_c; break; }
    done
fi
[ -n "$EDK2" ] && [ -r "$EDK2" ] || { printf 'run-vm: EDK2 aarch64 firmware not found\n' >&2; exit 2; }

# Native mode needs the QEMU binary resolved before the command line is
# built (dash's set -u rejects the unset reference otherwise).
if [ "$CONTMODE" != "1" ]; then
    QEMU=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
    command -v "$QEMU" >/dev/null 2>&1 || { printf 'run-vm: %s not found\n' "$QEMU" >&2; exit 2; }
fi

if [ -z "$VARS" ]; then
    VARS=$(mktemp "${TMPDIR:-/tmp}/duranium-vars.XXXXXX")
fi
if [ ! -s "$VARS" ]; then
    dd if=/dev/zero of="$VARS" bs=1M count=64 status=none
fi

# Resolve every backing file to a mountable host directory plus a fixed inner
# path, so native and container modes share one command-line construction.
_dir_of() {
    CDPATH= cd -- "$(dirname -- "$1")" && pwd
}

_disk_dir=$(_dir_of "$DISK")
_disk_name=$(basename "$DISK")
_log_dir=$(_dir_of "$LOG")
_log_name=$(basename "$LOG")
_vars_dir=$(_dir_of "$VARS")
_vars_name=$(basename "$VARS")
_fw_dir=$(_dir_of "$EDK2")
_fw_name=$(basename "$EDK2")

if [ -n "$TESTDATA" ]; then
    [ -r "$TESTDATA" ] || { printf 'run-vm: testdata not found: %s\n' "$TESTDATA" >&2; exit 2; }
    _test_dir=$(_dir_of "$TESTDATA")
    _test_name=$(basename "$TESTDATA")
fi

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

if [ "$CONTMODE" = "1" ]; then
    # The Docker VM has limited RAM; the fixture guest is a minimal Alpine
    # and does not need more than this.
    [ "$MEMORY" -le 512 ] || MEMORY=512
fi

if [ "$CONTMODE" = "1" ]; then
    # All guest I/O must live on VM-local storage: a docker volume. The disk
    # backing file on a host-shared filesystem has been observed to serve
    # stale content for freshly written blocks to a later QEMU boot (both
    # Docker Desktop virtiofs and colima's shared mount), even though the
    # host file is byte-correct. QEMU here reads and writes only /stage.
    STAGE=${DURANIUM_STAGE_VOLUME:-}
    [ -n "$STAGE" ] || { printf 'run-vm: DURANIUM_STAGE_VOLUME is required in container mode\n' >&2; exit 2; }
    _stage_run() {
        docker run --rm --platform linux/arm64 -v "$STAGE:/stage" alpine:3.20 sh -c "$1"
    }
    # Firmware: stage once via stdin (the host path may not be shared).
    if ! _stage_run '[ -s /stage/.edk2.fd ]'; then
        docker run -i --rm --platform linux/arm64 -v "$STAGE:/stage" \
            alpine:3.20 sh -c 'cat > /stage/.edk2.fd' < "$EDK2" || exit 2
    fi
    # Fresh UEFI variable store per boot.
    _stage_run 'dd if=/dev/zero of=/stage/vars.fd bs=1M count=64 status=none' || exit 2
    set -- docker run --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 sh -c "
            apk add -q qemu-system-aarch64 >/dev/null 2>&1
            exec qemu-system-aarch64 \"\$@\"
            " \
        _qemu \
        -M virt,highmem=on -accel tcg -cpu cortex-a72 -smp 2 -m "$MEMORY" \
        -drive if=pflash,format=raw,readonly=on,file=/stage/.edk2.fd \
        -drive if=pflash,format=raw,file=/stage/vars.fd \
        -drive "if=none,id=sys,file=/stage/disk.img,format=raw,cache=none,aio=threads" \
        -device virtio-blk-pci,drive=sys
    if [ -n "$TESTDATA" ]; then
        set -- "$@" \
            -drive "if=none,id=testdata,file=/stage/testdata.img,format=raw,readonly=on" \
            -device virtio-blk-pci,drive=testdata
    fi
    if [ "$INTERACTIVE" = "1" ]; then
        set -- "$@" -serial mon:stdio -display none -no-reboot
    else
        set -- "$@" -display none -serial "file:/stage/boot.log" -monitor none -no-reboot
    fi
else
    set -- "$QEMU" \
        -M virt,highmem=on $ACCEL_ARGS -smp 2 -m "$MEMORY" \
        -drive if=pflash,format=raw,readonly=on,file="$EDK2" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive "if=none,id=sys,file=$DISK,format=raw,cache=writethrough" \
        -device virtio-blk-pci,drive=sys
    if [ -n "${_test_dir:-}" ]; then
        set -- "$@" \
            -drive "if=none,id=testdata,file=$TESTDATA,format=raw,readonly=on" \
            -device virtio-blk-pci,drive=testdata
    fi
    if [ "$INTERACTIVE" = "1" ]; then
        set -- "$@" -serial mon:stdio -display none -no-reboot
    else
        set -- "$@" -display none -serial "file:$LOG" -monitor none -no-reboot
    fi
fi

if [ "$INTERACTIVE" = "1" ]; then
    exec "$@"
fi

"$@" &
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
if [ "$RC" = "0" ]; then
    wait "$PID" 2>/dev/null || RC=$?
fi
if [ "$CONTMODE" = "1" ]; then
    # The serial log was written VM-locally; fetch it to the host path.
    docker run --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 cat /stage/boot.log > "$LOG" 2>/dev/null || true
fi
exit "$RC"
