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

# mark-good must NOT hash the root device: it runs on the mounted root, and
# a mounted ext4's raw bytes are not a function of the installed image (the
# kernel's journal/superblock buffers live in the block-device page cache
# and read-only mounts never write them back). The root hash belongs to the
# pre-mount boot check (slot_boot_verify), which is the next block's job.
test_init mark-good-no-root-hash
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (no-root-hash)" "A" "$(sim_boot)"
assert_ok "install into B" dk update install "$T/art-b"
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_ok "OS confirms the boot" dk boot-confirm
printf 'post-install-garbage\n' >> "$T/root/slots/B.img"
assert_ok "mark-good succeeds without reading the device" dk mark-good B
assert_slot_status "B is GOOD" B GOOD

# The root hash runs pre-mount in slot_boot_verify: corruption inside the
# installed image must be rejected there, while partition headroom beyond
# image_size is tolerated (image_sha256 covers exactly image_size bytes).
test_init boot-verify-root-hash
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (verify)" "A" "$(sim_boot)"
assert_ok "install into B" dk update install "$T/art-b"
assert_ok "pre-mount verify accepts a fresh install" dk boot-verify B
printf 'partition-headroom-garbage\n' >> "$T/root/slots/B.img"
assert_ok "headroom beyond image_size is tolerated" dk boot-verify B
printf 'corrupt\n' | dd of="$T/root/slots/B.img" bs=1 seek=4096 conv=notrunc status=none
assert_fail "corruption inside image_size is rejected pre-mount" dk boot-verify B

test_done
