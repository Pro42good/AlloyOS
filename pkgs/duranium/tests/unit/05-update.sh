#!/bin/sh
# Offline A/B updates: inactive-only writes, verification, failure handling.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init update
make_key
assert_eq "boot GOOD A" "A" "$(sim_boot)"
A_HASH1=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')

make_artifact "$T/art-b" 2.0 B-v2
assert_ok "install signed update into inactive B" dk update install "$T/art-b"
A_HASH2=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')
assert_eq "active A image unchanged by install" "$A_HASH1" "$A_HASH2"
assert_slot_status "B is PENDING" B PENDING
assert_slot_field "B has three attempts" B boot_attempts_remaining 3
assert_file "B entry has boot counter" "$T/root/boot/loader/entries/duranium-b+3.conf"
assert_contains "global pending is B" "$T/root/boot/duranium/global.meta" "pending_slot=B"

assert_eq "pending B boots" "B" "$(sim_boot)"
assert_ok "mark B GOOD" dk mark-good B
assert_slot_status "B is GOOD" B GOOD

B_HASH1=$(sha256sum "$T/root/slots/B.img" | awk '{print $1}')
make_artifact "$T/art-a" 3.0 A-v3
assert_ok "install update into A while B is active" dk update install "$T/art-a"
B_HASH2=$(sha256sum "$T/root/slots/B.img" | awk '{print $1}')
assert_eq "active B image unchanged by update to A" "$B_HASH1" "$B_HASH2"
assert_slot_status "A is PENDING after update" A PENDING
assert_file "A entry has boot counter" "$T/root/boot/loader/entries/duranium-a+3.conf"

# Signature failure must not activate the new slot.
test_init update-bad-signature
make_key
make_artifact "$T/art-bad" 2.0 B-bad
printf 'tamper' >> "$T/art-bad/system.img"
assert_eq "boot GOOD A (bad signature)" "A" "$(sim_boot)"
A_HASH1=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')
assert_fail "tampered payload rejected" dk update install "$T/art-bad"
assert_slot_status "B not activated on signature failure" B UNKNOWN
assert_eq "A still active after signature failure" "A" "$(fake_boot)"
assert_eq "active A unchanged after signature failure" "$A_HASH1" "$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')"

# Write failure must not change the current boot selection.
test_init update-write-fail
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (write failure)" "A" "$(sim_boot)"
A_HASH1=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')
assert_fail "injected write failure fails install" \
    dk_env "DURANIUM_TEST_PARTIAL_WRITE_BYTES=1024" update install "$T/art-b"
assert_slot_status "target B is BAD after failed write" B BAD
assert_eq "A still active after failed write" "A" "$(fake_boot)"
assert_eq "active A unchanged after failed write" "$A_HASH1" "$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')"
assert_contains "no pending slot after failed write" "$T/root/boot/duranium/global.meta" "pending_slot="

# Read-back failure aborts before activation.
test_init update-readback-fail
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (readback failure)" "A" "$(sim_boot)"
assert_fail "injected read-back failure fails install" \
    dk_env "DURANIUM_TEST_FAIL_AT=readback" update install "$T/art-b"
assert_slot_status "B is BAD after read-back failure" B BAD
assert_eq "A still active after read-back failure" "A" "$(fake_boot)"

# Power loss: process dies after a partial write. Metadata still says the
# target is in progress, and the next boot reconciliation marks it BAD.
test_init update-power-loss
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A (power loss)" "A" "$(sim_boot)"
A_HASH1=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')
( dk_env "DURANIUM_TEST_PARTIAL_WRITE_BYTES=1024 DURANIUM_TEST_POWER_LOSS=1" \
    update install "$T/art-b" ) >/dev/null 2>&1
assert_contains "power loss leaves update_in_progress" "$T/root/boot/duranium/global.meta" "update_in_progress=B"
assert_ok "reconcile interrupted update" dk boot-reconcile
assert_slot_status "interrupted target B is BAD" B BAD
assert_eq "A still active after power loss" "A" "$(fake_boot)"
assert_eq "active A unchanged after power loss" "$A_HASH1" "$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')"

test_done
