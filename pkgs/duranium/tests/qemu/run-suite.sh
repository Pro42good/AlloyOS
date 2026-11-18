#!/bin/sh
# Automated Duranium QEMU suite.
#
# Each scenario gets a fresh copy of the fixture disk and boots until the guest
# prints DURANIUM_TEST:DONE or DURANIUM_TEST:FAIL. Unbootable-slot boots simply
# time out and are retried; systemd-boot consumes one attempt per boot.
#
# Container mode (default) runs QEMU inside an Alpine container and keeps all
# disk I/O on a docker volume: guest reads/writes never touch a host-shared
# filesystem, whose stale-read behavior for freshly written blocks has been
# observed to corrupt verification across boots on macOS. See run-vm.sh.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
OUT="$PKG/qemu/out"
RUNROOT="$OUT/runs/$(date +%Y%m%d-%H%M%S)"
FIXTURE="$OUT/duranium-fixture.img"
TESTDATA="$OUT/testdata.img"
RUNVM="$PKG/qemu/run-vm.sh"
TIMEOUT=${DURANIUM_QEMU_TIMEOUT:-75}
# Container mode (default) trades speed for a coherent guest block-device
# view; see run-vm.sh. TCG boots need a larger timeout.
if [ "${DURANIUM_QEMU_IN_CONTAINER:-1}" = "1" ]; then
    CONTFLAG=--in-container
    [ -n "${DURANIUM_QEMU_TIMEOUT:-}" ] && TIMEOUT=$DURANIUM_QEMU_TIMEOUT || TIMEOUT=600
else
    CONTFLAG=""
fi

command -v docker >/dev/null 2>&1 || { printf 'run-suite: Docker is required\n' >&2; exit 2; }
[ -x "$RUNVM" ] || { printf 'run-suite: missing %s\n' "$RUNVM" >&2; exit 2; }

if [ "${1:-}" = "--rebuild" ] || [ ! -r "$FIXTURE" ] || [ ! -r "$TESTDATA" ]; then
    printf '== building fixture ==\n'
    "$PKG/qemu/build-fixture.sh" || exit 1
fi
[ -r "$OUT/fixture.env" ] || { printf 'run-suite: missing fixture.env\n' >&2; exit 2; }
. "$OUT/fixture.env"
mkdir -p "$RUNROOT"

if [ -n "$CONTFLAG" ]; then
    STAGE="dur-suite-$(date +%Y%m%d-%H%M%S)"
    docker volume create "$STAGE" >/dev/null || exit 1
    export DURANIUM_STAGE_VOLUME="$STAGE"
    trap 'docker volume rm "$STAGE" >/dev/null 2>&1 || true' EXIT INT TERM
fi

# Stage the fixture disk into the VM-local volume. Stream it from the host
# via stdin: reading large files through the shared filesystem from inside
# the VM has been observed to return garbage at high offsets (both Docker
# Desktop virtiofs and colima's shared mount). Host-native reads of these
# files have always been correct. The staged copy is hashed back against the
# host-side hash so staging corruption fails loudly instead of surfacing as
# phantom verification failures later.
stage_disk() {
    _want=$(shasum -a 256 < "$FIXTURE" | awk '{print $1}')
    docker run -i --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 sh -c '
        cat > /stage/disk.img
        sync' < "$FIXTURE" || return 1
    _got=$(docker run --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 sh -c 'apk add -q coreutils >/dev/null 2>&1; sha256sum /stage/disk.img | awk "{print \$1}"')
    if [ "$_want" != "$_got" ]; then
        printf 'run-suite: staged disk corrupt (want %s got %s)\n' "$_want" "$_got" >&2
        return 1
    fi
}

set_scenario() {
    _name=$1
    # testdata is streamed from the host (never read through the shared
    # filesystem from inside the VM), then the scenario marker is set on the
    # VM-local copy with debugfs.
    docker run -i --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 sh -c "
        cat > /stage/testdata.img
        apk add -q e2fsprogs e2fsprogs-extra >/dev/null 2>&1
        debugfs -w -R 'rm /scenario' /stage/testdata.img >/dev/null 2>&1 || true
        printf '%s\n' '$_name' > /tmp/scenario
        debugfs -w -R 'write /tmp/scenario /scenario' /stage/testdata.img >/dev/null 2>&1
        sync" < "$TESTDATA" || return 1
}

corrupt_slot() {
    _offset=$1
    docker run --rm --platform linux/arm64 -v "$STAGE:/stage" alpine:3.20 sh -c "
        dd if=/dev/zero of=/stage/disk.img bs=1M seek=$_offset count=1 conv=notrunc status=none
        sync" || return 1
}

# Fetch the VM-local serial log to the host after each boot.
fetch_log() {
    docker run --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 cat /stage/boot.log > "$1" 2>/dev/null
}

# On failure, keep the guest-written disk for debugging.
fetch_disk() {
    docker run --rm --platform linux/arm64 -v "$STAGE:/stage" \
        alpine:3.20 cat /stage/disk.img > "$1" 2>/dev/null
}

run_scenario() {
    _name=$1
    _max_boots=$2
    _pre_corrupt=$3
    _label=${4:-$_name}
    _dir="$RUNROOT/$_label"
    mkdir -p "$_dir"
    printf '\n== scenario: %s ==\n' "$_name"
    set_scenario "$_name" || { printf 'FAIL: could not set scenario\n' >&2; return 1; }
    stage_disk || { printf 'FAIL: could not stage disk\n' >&2; return 1; }

    _n=0
    while [ "$_n" -lt "$_max_boots" ]; do
        _n=$((_n + 1))
        _log="$_dir/boot-$_n.log"
        printf '  boot %s/%s ... ' "$_n" "$_max_boots"
        if [ "$_pre_corrupt" = "both" ]; then
            corrupt_slot "$A_OFFSET_MB" && corrupt_slot "$B_OFFSET_MB"
        elif [ "$_pre_corrupt" = "a" ]; then
            corrupt_slot "$A_OFFSET_MB"
        elif [ "$_pre_corrupt" = "b" ]; then
            corrupt_slot "$B_OFFSET_MB"
        fi

        "$RUNVM" $CONTFLAG --disk "$RUNROOT/disk-placeholder" \
            --testdata "$TESTDATA" --log "$_log" --timeout "$TIMEOUT"
        _rc=$?
        fetch_log "$_log"
        if grep -aq 'DURANIUM_TEST:FAIL' "$_log"; then
            printf 'FAIL\n'
            grep -a 'DURANIUM_TEST:FAIL' "$_log" | tail -n 1
            fetch_disk "$_dir/disk.img"
            return 1
        fi
        if grep -aq 'DURANIUM_TEST:DONE' "$_log"; then
            printf 'DONE\n'
            return 0
        fi
        if grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_A' "$_log"; then
            printf 'request corrupt A\n'
            corrupt_slot "$A_OFFSET_MB"
        elif grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_B' "$_log"; then
            printf 'request corrupt B\n'
            corrupt_slot "$B_OFFSET_MB"
        elif grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_BOTH' "$_log"; then
            printf 'request corrupt both\n'
            corrupt_slot "$A_OFFSET_MB"
            corrupt_slot "$B_OFFSET_MB"
        else
            printf 'retry (rc=%s)\n' "$_rc"
        fi
    done
    fetch_disk "$_dir/disk.img"
    printf 'FAIL: no completion after %s boots\n' "$_max_boots"
    return 1
}

PASS=0
FAIL=0
printf 'Duranium QEMU suite\n'
if [ -n "$CONTFLAG" ]; then
    printf 'stage:     docker volume %s\n' "$STAGE"
fi
printf 'fixture:  %s\n' "$FIXTURE"
printf 'testdata: %s\n' "$TESTDATA"
printf 'runs:     %s\n' "$RUNROOT"

run_one() {
    case "$1" in
        acceptance) run_scenario acceptance 14 none ;;
        failures) run_scenario failures 6 none ;;
        recovery) run_scenario recovery 6 both recovery-both ;;
        recovery-a) run_scenario recovery 6 a recovery-a ;;
        recovery-mixed) run_scenario recovery-mixed 8 b recovery-mixed ;;
        corrupt-boot) run_scenario corrupt-boot 10 none ;;
        *) printf 'unknown scenario: %s\n' "$1" >&2; return 1 ;;
    esac
}

SELECT=${DURANIUM_QEMU_SCENARIOS:-"acceptance failures recovery recovery-a recovery-mixed corrupt-boot"}
for _s in $SELECT; do
    if run_one "$_s"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
done

printf '\nQEMU SUMMARY: %s passed, %s failed\n' "$PASS" "$FAIL"
printf 'logs: %s\n' "$RUNROOT"
[ "$FAIL" -eq 0 ]
