#!/bin/sh
# QEMU integration test agent.
#
# The host boots the VM repeatedly. Each boot reads the current phase from
# STATE, runs one scenario step, and powers off. This makes unbootable-slot
# tests possible: the agent simply never runs on the broken slot, and the next
# boot continues at the same phase.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
MODE=${1:-normal}
STATE=/state/test
PHASE_FILE="$STATE/phase"

mkdir -p "$STATE"
sync 2>/dev/null || true

# Test-data disk is read-only. The recovery init may already have mounted it.
mkdir -p /testdata
if [ -b /dev/vdb ] && ! grep -q ' /testdata ' /proc/mounts; then
    mount -t ext4 -o ro /dev/vdb /testdata 2>/dev/null || true
fi

log() {
    printf 'DURANIUM_TEST:%s\n' "$*"
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$STATE/agent.log" 2>/dev/null || true
}

fail() {
    log "FAIL $*"
    printf '%s\n' "$*" > "$STATE/failure" 2>/dev/null || true
    sync 2>/dev/null || true
    poweroff -f 2>/dev/null || exit 1
}

advance() {
    _next=$((phase + 1))
    printf '%s\n' "$_next" > "$PHASE_FILE"
    sync 2>/dev/null || true
    log "ADVANCE phase=$_next"
    poweroff -f 2>/dev/null || exit 0
}

finish() {
    printf 'completed\n' > "$STATE/done" 2>/dev/null || true
    sync 2>/dev/null || true
    log "DONE"
    poweroff -f 2>/dev/null || exit 0
}

request_corrupt() {
    _next=$((phase + 1))
    printf '%s\n' "$_next" > "$PHASE_FILE"
    log "REQUEST_CORRUPT_$1"
    sync 2>/dev/null || true
    poweroff -f 2>/dev/null || exit 0
}

pass() {
    log "PASS $*"
}

expect_eq() {
    _desc=$1
    _want=$2
    _got=$3
    if [ "$_want" = "$_got" ]; then
        pass "$_desc"
    else
        fail "$_desc (want '$_want', got '$_got')"
    fi
}

expect_match() {
    _desc=$1
    _text=$2
    _pattern=$3
    case "$_text" in
        *"$_pattern"*) pass "$_desc" ;;
        *) fail "$_desc (missing '$_pattern' in '$_text')" ;;
    esac
}

expect_file() {
    _desc=$1
    _path=$2
    [ -e "$_path" ] && pass "$_desc" || fail "$_desc (missing $_path)"
}

expect_no_file() {
    _desc=$1
    _path=$2
    [ ! -e "$_path" ] && pass "$_desc" || fail "$_desc (unexpected $_path)"
}

expect_contains() {
    _desc=$1
    _path=$2
    _text=$3
    if [ -r "$_path" ] && grep -q -- "$_text" "$_path"; then
        pass "$_desc"
    else
        fail "$_desc (missing '$_text' in $_path)"
    fi
}

run_or_fail() {
    _desc=$1
    shift
    if "$@" > "$STATE/last.out" 2>&1; then
        pass "$_desc"
    else
        fail "$_desc (command failed: $*)"
    fi
}

expect_fail() {
    _desc=$1
    shift
    if "$@" > "$STATE/last.out" 2>&1; then
        fail "$_desc (command unexpectedly succeeded: $*)"
    else
        pass "$_desc"
    fi
}

slot_field() {
    _slot=$1
    _field=$2
    duranium slot show "$_slot" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$_field=//p" | head -n 1
}

expect_slot_status() {
    _slot=$1
    _want=$2
    expect_eq "slot $_slot status $_want" "$_want" "$(slot_field "$_slot" status)"
}

status_field() {
    _field=$1
    duranium status 2>/dev/null | sed -n "s/.*$_field: \([^ ]*\).*/\1/p" | head -n 1
}

expect_active() {
    expect_eq "active slot $1" "$1" "$(status_field active)"
}

expect_pending() {
    expect_eq "pending slot ${1:-none}" "${1:-none}" "$(status_field pending)"
}

expect_booted() {
    _want=$1
    _got=$(sed -n 's/^slot=//p' /run/duranium/boot.env 2>/dev/null | head -n 1)
    [ -n "$_got" ] || _got=$(sed -n 's/^slot=//p' /etc/duranium/slot 2>/dev/null | head -n 1)
    expect_eq "booted slot $_want" "$_want" "$_got"
}

root_is_ro() {
    awk '$2 == "/" { print $4 }' /proc/mounts | grep -q 'ro'
}

state_is_mounted() {
    grep -q ' /state ' /proc/mounts
}


write_ephemeral() {
    mkdir -p /tmp /run /var/tmp 2>/dev/null || true
    printf 'ephemeral\n' > /tmp/duranium-ephemeral
    printf 'ephemeral\n' > /run/duranium-ephemeral
    printf 'ephemeral\n' > /var/tmp/duranium-ephemeral
    sync 2>/dev/null || true
}

check_ephemeral_gone() {
    if [ -e /tmp/duranium-ephemeral ] || [ -e /run/duranium-ephemeral ] || [ -e /var/tmp/duranium-ephemeral ]; then
        fail "ephemeral data survived reboot"
    fi
    pass "ephemeral data cleared across reboot"
}

seed_state_files() {
    expect_eq "seed settings present" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
    expect_eq "seed user file present" "seed-user" "$(cat /state/home/user/seed.txt 2>/dev/null)"
}

write_user_state() {
    mkdir -p /state/home/user 2>/dev/null || true
    printf 'acceptance-user\n' > /state/home/user/acceptance.txt
    printf 'acceptance-setting\n' > /state/etc/alloy/settings.conf
    sync 2>/dev/null || true
}

check_user_state() {
    expect_eq "user state survives" "acceptance-user" "$(cat /state/home/user/acceptance.txt 2>/dev/null)"
    expect_eq "settings survive" "acceptance-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
}

if [ ! -r /testdata/scenario ]; then
    log "NO_SCENARIO"
    exit 0
fi
SCENARIO=$(tr -d '\n' < /testdata/scenario)
if [ ! -r "/testdata/scenarios/$SCENARIO.sh" ]; then
    fail "missing scenario script $SCENARIO"
fi
. "/testdata/scenarios/$SCENARIO.sh"

phase=$(cat "$PHASE_FILE" 2>/dev/null | tr -d '\n')
[ -n "$phase" ] || phase=0
log "BOOT mode=$MODE scenario=$SCENARIO phase=$phase slot=$(cat /etc/duranium/slot 2>/dev/null)"

scenario_step "$phase"
log "STEP_RETURNED_WITHOUT_ACTION phase=$phase"
fail "scenario step $phase returned without advance/done/fail/request"
