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
assert_fail "mark-good without OS boot-confirm is refused" dk mark-good B
assert_slot_status "pending B stays PENDING without confirm" B PENDING
assert_ok "boot-confirm records the OS confirmation" dk boot-confirm
assert_slot_status "pending B stays PENDING after confirm" B PENDING
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
assert_ok "OS confirms the boot" dk boot-confirm
assert_fail "failed health refuses mark-good" dk_env "DURANIUM_TEST_HEALTH_FAIL=1" mark-good B
assert_slot_status "B stays PENDING after health failure" B PENDING
rm -f "$T/run/alloy/core-ready"
assert_fail "missing core readiness refuses mark-good" dk mark-good B
assert_slot_status "B stays PENDING after missing core" B PENDING

# mark-good must verify the root image hash recorded at install time; a
# slot whose root silently corrupted after install must stay PENDING.
test_init mark-good-root-hash
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A" "A" "$(sim_boot)"
assert_ok "install into B" dk update install "$T/art-b"
assert_eq "boot pending B" "B" "$(sim_boot)"
printf 'corrupt\n' >> "$T/root/slots/B.img"
assert_fail "root image hash mismatch refuses mark-good" dk mark-good B
assert_slot_status "B stays PENDING after root mismatch" B PENDING

# image_sha256 covers exactly image_size bytes, not the slot "partition":
# partitions are provisioned with headroom, and the tail must not be hashed.
# (Regression: hashing the whole partition made mark-good permanently refuse
# every image smaller than its partition.)
test_init mark-good-image-size
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (image-size)" "A" "$(sim_boot)"
assert_ok "install into B" dk update install "$T/art-b"
printf 'partition-headroom-garbage\n' >> "$T/root/slots/B.img"
assert_eq "boot pending B with partition headroom" "B" "$(sim_boot)"
assert_ok "OS confirms the boot" dk boot-confirm
assert_ok "mark-good ignores bytes beyond image_size" dk mark-good B
assert_slot_status "B is GOOD despite partition headroom" B GOOD
assert_slot_field "B recorded image_size" B image_size 1048576

test_done
