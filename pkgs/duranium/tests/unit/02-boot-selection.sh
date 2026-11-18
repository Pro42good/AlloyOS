#!/bin/sh
# Boot selection: GOOD A, pending B priority, attempt accounting, BAD fallback.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init boot-select

assert_eq "GOOD A boots normally" "A" "$(fake_boot)"

make_slot_pending B 2.0 B-v2 1 A
assert_eq "PENDING B takes priority over A" "B" "$(fake_boot)"
dk boot-record B >/dev/null
assert_slot_status "B still PENDING without confirmation" B PENDING
assert_slot_field "first failed/ pending boot decrements attempts" B boot_attempts_remaining 2

assert_eq "PENDING B still selected on second boot" "B" "$(fake_boot)"
dk boot-record B >/dev/null
assert_slot_field "second boot decrements attempts" B boot_attempts_remaining 1

assert_eq "PENDING B still selected on third boot" "B" "$(fake_boot)"
if dk boot-record B >/dev/null 2>&1; then
    fail "third pending boot should exhaust attempts and request fallback"
else
    ok
fi
assert_slot_status "exhausted B is marked BAD" B BAD
assert_eq "no pending slot remains" "none" "$(dk status | sed -n 's/.*pending: \([^ ]*\).*/\1/p')"
assert_eq "fallback is A" "A" "$(fake_boot)"

# BAD is not retried.
assert_eq "BAD B is not retried" "A" "$(fake_boot)"

# Simulate a completely unbootable pending slot: it has no entry, so
# reconciliation marks it BAD and A remains bootable.
test_init boot-select-missing-entry
make_slot_pending B 2.0 B-v2 1 A
rm -f "$T/root/boot/loader/entries"/duranium-b*.conf
dk boot-reconcile >/dev/null 2>&1 || true
assert_slot_status "missing pending entry is marked BAD" B BAD
assert_eq "A still boots when B is unbootable" "A" "$(fake_boot)"

# A GOOD slot is not selected ahead of a pending slot, and a GOOD B becomes
# the normal active slot only via mark-good.
test_init boot-select-good-b
make_slot_good B 2.0 B-v2
set_global B "" A B
dk admin sync >/dev/null
assert_eq "GOOD active B boots" "B" "$(fake_boot)"

# Corrupt metadata must not be booted automatically.
test_init boot-select-corrupt-metadata
printf 'garbage\n' > "$T/root/boot/duranium/slots/A.meta"
printf 'garbage\n' > "$T/root/boot/duranium/slots/A.meta.bak"
assert_fail "boot-record fails safely on corrupt metadata" dk boot-record A
assert_fail "corrupt slot is not shown as GOOD" dk slot show A

# A GOOD slot whose entry still carries a boot counter (mark-good crash
# window: slot and global metadata committed, bootloader_sync lost) must be
# repaired by boot-reconcile instead of decaying into an unbootable entry
# while metadata says the slot is the active one.
test_init boot-select-good-stale-counter
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_ok "OS confirms the boot" dk boot-confirm
assert_ok "mark B GOOD" dk mark-good B
mv "$T/root/boot/loader/entries/duranium-b.conf" \
   "$T/root/boot/loader/entries/duranium-b+2-1.conf"
assert_ok "reconcile repairs GOOD entry with stale counter" dk boot-reconcile
assert_contains "B entry counterless after repair" \
    "$T/root/boot/loader/entries/duranium-b.conf" "Alloy B"
assert_no_file "counter entry removed" "$T/root/boot/loader/entries/duranium-b+2-1.conf"
assert_eq "B still boots after repair" "B" "$(fake_boot)"
assert_eq "B keeps booting (no counter decay)" "B" "$(fake_boot)"

# A pending pointer naming a non-PENDING slot (e.g. global metadata restored
# from an older backup) must be cleared by reconciliation; otherwise every
# future update is refused.
test_init boot-select-stale-pending
make_key
make_artifact "$T/art-c" 3.0 C-v3
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
dk admin init-slot B \
    alloy_version=2.0 build_id=B-v2 profile=dev architecture=aarch64 \
    hardware_target=qemu-aarch64-virt state_schema=1 status=BAD known_good=0 \
    boot_attempts_remaining=0 max_boot_attempts=3 \
    image_sha256=0000000000000000000000000000000000000000000000000000000000000000 \
    boot_kernel_sha256=0000000000000000000000000000000000000000000000000000000000000000 \
    boot_initramfs_sha256=0000000000000000000000000000000000000000000000000000000000000000 >/dev/null
dk admin init-global active_slot=A pending_slot=B fallback_slot=A \
    last_known_good_slot=A update_in_progress= >/dev/null
assert_ok "reconcile clears stale pending pointer" dk boot-reconcile
assert_not_contains "no pending slot remains" "$T/root/boot/duranium/global.meta" "pending_slot=B"
# The test process booted B; simulate the reboot into the (GOOD) active slot
# before installing, as a real boot would.
rm -f "$T/run/boot.env"
assert_ok "update install works after stale pointer cleared" dk update install "$T/art-c"

# A file that merely shares the slot-name prefix is not a slot entry and
# must not poison boot-record or reconciliation.
test_init boot-select-prefix
make_slot_pending B 2.0 B-v2 1 A
printf 'title unrelated\nsort-key 99-note\n' \
    > "$T/root/boot/loader/entries/duranium-b-notes.conf"
assert_eq "pending B boots with foreign prefix file present" "B" "$(sim_boot)"
assert_slot_status "pending B unaffected by foreign entry" B PENDING
assert_slot_field "attempts still tracked" B boot_attempts_remaining 2
assert_ok "reconcile ignores foreign prefix entries" dk boot-reconcile
assert_slot_status "pending B still PENDING after reconcile" B PENDING
assert_file "foreign entry untouched" "$T/root/boot/loader/entries/duranium-b-notes.conf"

# A PENDING slot that is no longer named by the pending pointer is a stale
# orphan: its +N entry outranks the GOOD active slot forever.
test_init stale-pending-orphan
make_slot_pending B 2.0 B-v2 1 A
set_global A "" A A
assert_ok "reconcile runs with pointer cleared" dk boot-reconcile
assert_slot_status "stale orphan B marked BAD" B BAD
assert_no_file "orphan counter entry removed" "$T/root/boot/loader/entries/duranium-b+3.conf"

# A non-numeric counter suffix is a malformed entry, not a free pass.
test_init malformed-counter-entry
make_slot_pending B 2.0 B-v2 1 A
mv "$T/root/boot/loader/entries/duranium-b+3.conf" \
    "$T/root/boot/loader/entries/duranium-b+abc.conf"
assert_ok "reconcile runs with malformed entry" dk boot-reconcile
assert_slot_status "malformed counter marks B BAD" B BAD

test_done
