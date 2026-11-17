#!/bin/sh
# mark-good: explicit confirmation, boot identity, health gate, accounting.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init mark-good
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_slot_status "pending B stays PENDING" B PENDING
assert_slot_field "attempts after boot" B boot_attempts_remaining 2

assert_ok "healthy pending slot marks GOOD" dk mark-good B
assert_slot_status "B is GOOD after confirmation" B GOOD
assert_slot_field "B attempts reset" B boot_attempts_remaining 0
assert_contains "B boot entry has no counter" "$T/root/boot/loader/entries/duranium-b.conf" "title Alloy B"
assert_no_file "counter entry removed" "$T/root/boot/loader/entries/duranium-b+2-1.conf"
dk status > "$T/status.out" 2>/dev/null || true
assert_contains "active slot is B" "$T/status.out" "active: B"
assert_contains "fallback slot is A" "$T/status.out" "fallback: A"
assert_contains "no pending slot" "$T/status.out" "pending: none"

# Only the currently booted pending slot may mark itself GOOD.
test_init mark-good-wrong-slot
make_slot_pending B 2.0 B-v2 1 A
dk boot-record A >/dev/null 2>&1 || true
assert_fail "mark-good B while running A is refused" dk mark-good B
assert_slot_status "B remains PENDING" B PENDING

# Failed health check refuses confirmation.
test_init mark-good-health
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_fail "failed health refuses mark-good" dk_env "DURANIUM_TEST_HEALTH_FAIL=1" mark-good B
assert_slot_status "B stays PENDING after health failure" B PENDING
rm -f "$T/run/alloy/core-ready"
assert_fail "missing core readiness refuses mark-good" dk mark-good B
assert_slot_status "B stays PENDING after missing core" B PENDING

test_done
