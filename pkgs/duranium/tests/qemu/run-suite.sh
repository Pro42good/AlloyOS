#!/bin/sh
# Automated Duranium QEMU suite.
#
# Each scenario gets a fresh copy of the fixture disk and boots until the guest
# prints DURANIUM_TEST:DONE or DURANIUM_TEST:FAIL. Unbootable-slot boots simply
# time out and are retried; systemd-boot consumes one attempt per boot.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
OUT="$PKG/qemu/out"
RUNROOT="$OUT/runs/$(date +%Y%m%d-%H%M%S)"
FIXTURE="$OUT/duranium-fixture.img"
TESTDATA="$OUT/testdata.img"
RUNVM="$PKG/qemu/run-vm.sh"
TIMEOUT=${DURANIUM_QEMU_TIMEOUT:-75}

command -v docker >/dev/null 2>&1 || { printf 'run-suite: Docker is required\n' >&2; exit 2; }
[ -x "$RUNVM" ] || { printf 'run-suite: missing %s\n' "$RUNVM" >&2; exit 2; }

if [ "${1:-}" = "--rebuild" ] || [ ! -r "$FIXTURE" ] || [ ! -r "$TESTDATA" ]; then
    printf '== building fixture ==\n'
    "$PKG/qemu/build-fixture.sh" || exit 1
fi
[ -r "$OUT/fixture.env" ] || { printf 'run-suite: missing fixture.env\n' >&2; exit 2; }
. "$OUT/fixture.env"
mkdir -p "$RUNROOT"

copy_disk() {
    _src=$1
    _dst=$2
    rm -f "$_dst"
    if cp -c "$_src" "$_dst" 2>/dev/null; then
        return 0
    fi
    if cp --reflink=auto "$_src" "$_dst" 2>/dev/null; then
        return 0
    fi
    cp "$_src" "$_dst"
}

set_scenario() {
    _name=$1
    docker run --rm -v "$OUT:/out" --platform linux/arm64 alpine:3.20 sh -c "
        apk add -q e2fsprogs e2fsprogs-extra >/dev/null 2>&1
        debugfs -w -R 'rm /scenario' /out/testdata.img >/dev/null 2>&1 || true
        printf '%s\n' '$_name' > /tmp/scenario
        debugfs -w -R 'write /tmp/scenario /scenario' /out/testdata.img >/dev/null
    " || return 1
}

corrupt_slot() {
    _disk=$1
    _offset=$2
    dd if=/dev/zero of="$_disk" bs=1M seek="$_offset" count=1 conv=notrunc status=none
}

run_scenario() {
    _name=$1
    _max_boots=$2
    _pre_corrupt=$3
    _label=${4:-$_name}
    _dir="$RUNROOT/$_label"
    mkdir -p "$_dir"
    _disk="$_dir/disk.img"
    printf '\n== scenario: %s ==\n' "$_name"
    set_scenario "$_name" || { printf 'FAIL: could not set scenario\n' >&2; return 1; }
    copy_disk "$FIXTURE" "$_disk" || return 1
    if [ "$_pre_corrupt" = "both" ]; then
        corrupt_slot "$_disk" "$A_OFFSET_MB"
        corrupt_slot "$_disk" "$B_OFFSET_MB"
    elif [ "$_pre_corrupt" = "a" ]; then
        corrupt_slot "$_disk" "$A_OFFSET_MB"
    elif [ "$_pre_corrupt" = "b" ]; then
        corrupt_slot "$_disk" "$B_OFFSET_MB"
    fi

    _n=0
    while [ "$_n" -lt "$_max_boots" ]; do
        _n=$((_n + 1))
        _log="$_dir/boot-$_n.log"
        _vars="$_dir/vars-$_n.fd"
        printf '  boot %s/%s ... ' "$_n" "$_max_boots"
        "$RUNVM" --disk "$_disk" --testdata "$TESTDATA" --log "$_log" \
            --vars "$_vars" --timeout "$TIMEOUT"
        _rc=$?
        if grep -aq 'DURANIUM_TEST:FAIL' "$_log"; then
            printf 'FAIL\n'
            grep -a 'DURANIUM_TEST:FAIL' "$_log" | tail -n 1
            return 1
        fi
        if grep -aq 'DURANIUM_TEST:DONE' "$_log"; then
            printf 'DONE\n'
            return 0
        fi
        if grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_A' "$_log"; then
            printf 'request corrupt A\n'
            corrupt_slot "$_disk" "$A_OFFSET_MB"
        elif grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_B' "$_log"; then
            printf 'request corrupt B\n'
            corrupt_slot "$_disk" "$B_OFFSET_MB"
        elif grep -aq 'DURANIUM_TEST:REQUEST_CORRUPT_BOTH' "$_log"; then
            printf 'request corrupt both\n'
            corrupt_slot "$_disk" "$A_OFFSET_MB"
            corrupt_slot "$_disk" "$B_OFFSET_MB"
        else
            printf 'retry (rc=%s)\n' "$_rc"
        fi
    done
    printf 'FAIL: no completion after %s boots\n' "$_max_boots"
    return 1
}

PASS=0
FAIL=0
printf 'Duranium QEMU suite\n'
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
