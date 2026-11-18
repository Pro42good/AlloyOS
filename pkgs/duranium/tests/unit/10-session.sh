#!/bin/sh
# Boot/session confirmation handshake and crash detection:
#   * mark-good requires the OS boot-confirm for the current boot;
#   * an optional sign-in gate (session-confirm) can be required;
#   * a reported session crash refuses confirmation and marks a pending
#     slot BAD (no automatic retry);
#   * a previous boot that reached userland but never shut down cleanly is
#     detected on the next boot; a CLEAN record suppresses the detection.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

# The API requires a boot record: without one there is nothing to confirm.
test_init session-no-record
assert_fail "boot-confirm without boot-record refused" dk boot-confirm
assert_fail "session-confirm without boot-record refused" dk session-confirm

# Stage 1: the OS confirms the boot; mark-good requires it.
test_init session-confirm-gate
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_fail "mark-good without boot-confirm refused" dk mark-good B
assert_slot_status "B stays PENDING without confirm" B PENDING
assert_ok "boot-confirm accepts the booted slot" dk boot-confirm
assert_fail "boot-confirm for a foreign slot refused" dk boot-confirm A
assert_ok "mark-good after OS confirm" dk mark-good B
assert_slot_status "B is GOOD after confirmation" B GOOD
assert_contains "boot journal has CONFIRM" "$T/root/state/duranium/bootlog" "CONFIRM slot=B"

# Stage 2 (the sign-in gate): a stub in V1. Off by default, enforced when
# the deployment enables it (the Alloy desktop).
test_init session-require-session
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_ok "OS confirm" dk boot-confirm
assert_fail "mark-good refuses when sign-in confirmation is required" \
    dk_env "DURANIUM_REQUIRE_SESSION=1" mark-good B
assert_slot_status "B stays PENDING without session confirm" B PENDING
assert_ok "session-confirm accepts the booted slot" dk session-confirm
assert_ok "mark-good after sign-in confirmation" \
    dk_env "DURANIUM_REQUIRE_SESSION=1" mark-good B
assert_contains "boot journal has SESSION" "$T/root/state/duranium/bootlog" "SESSION slot=B"

# Ordering: session-confirm cannot run before boot-confirm.
test_init session-order
make_slot_pending B 2.0 B-v2 1 A
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_fail "session-confirm before boot-confirm refused" dk session-confirm
assert_ok "boot-confirm" dk boot-confirm
assert_ok "session-confirm after boot-confirm" dk session-confirm

# Crash handling: a reported session crash on the pending slot marks it BAD
# immediately (the OS judged the candidate unusable; no automatic retry).
test_init session-crash-pending
make_key
make_artifact "$T/art-b" 2.0 B-v2
assert_eq "boot GOOD A" "A" "$(sim_boot)"
assert_ok "install into B" dk update install "$T/art-b"
assert_eq "boot pending B" "B" "$(sim_boot)"
assert_ok "OS confirm" dk boot-confirm
assert_ok "sign-in confirm" dk session-confirm
assert_ok "session crash reported" dk session-crash "environment crashed after sign-in"
assert_slot_status "crashed pending slot is BAD" B BAD
assert_not_contains "pending pointer cleared" "$T/root/boot/duranium/global.meta" "pending_slot=B"
assert_eq "fallback A boots after crash" "A" "$(fake_boot)"

# A crash on a GOOD slot is recorded but never demotes it: GOOD changes
# only through explicit operator action in V1.
test_init session-crash-good
assert_eq "boot GOOD A" "A" "$(sim_boot)"
assert_ok "OS confirm" dk boot-confirm
assert_ok "session crash reported on GOOD slot" dk session-crash "compositor crash"
assert_slot_status "GOOD slot not demoted by crash report" A GOOD
assert_contains "crash recorded in journal" "$T/root/state/duranium/bootlog" "CRASH slot=A"

# Unclean-shutdown detection: the previous boot reached userland
# (confirmed + signed in) but never recorded a clean shutdown; the next
# boot detects it. A CLEAN record suppresses the detection.
test_init session-unclean
export DURANIUM_TEST_BOOT_ID=boot-1
assert_eq "first boot" "A" "$(sim_boot)"
assert_ok "OS confirm" dk boot-confirm
assert_ok "sign-in confirm" dk session-confirm
export DURANIUM_TEST_BOOT_ID=boot-2
assert_eq "second boot" "A" "$(sim_boot)"
assert_ok "boot-confirm detects unclean previous boot" dk boot-confirm
assert_contains "unclean shutdown detected" "$T/root/state/duranium/bootlog" "DETECTED slot=A boot_id=boot-1"
assert_ok "clean shutdown recorded" dk boot-clean
export DURANIUM_TEST_BOOT_ID=boot-3
assert_eq "third boot" "A" "$(sim_boot)"
assert_ok "boot-confirm after clean shutdown" dk boot-confirm
if grep -q "DETECTED slot=A boot_id=boot-2" "$T/root/state/duranium/bootlog"; then
    fail "clean boot was misdetected as unclean"
else
    ok
fi

test_done
