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

test_done
