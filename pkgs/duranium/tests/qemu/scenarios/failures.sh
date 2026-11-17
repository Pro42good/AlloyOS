#!/bin/sh
# Failure scenario: bad signatures, wrong profile/arch/hardware, failed writes,
# and a simulated power loss. The current GOOD slot must remain bootable.

scenario_step() {
    case "$1" in
    0)
        expect_booted A
        expect_slot_status A GOOD
        expect_active A
        _a_before=$(sha256sum /dev/vda3 | awk '{print $1}')

        expect_fail "tampered payload rejected" duranium update install /testdata/artifacts/bad-payload
        expect_fail "tampered manifest rejected" duranium update install /testdata/artifacts/bad-manifest
        expect_fail "untrusted key rejected" duranium update install /testdata/artifacts/bad-key
        expect_fail "wrong profile rejected" duranium update install /testdata/artifacts/wrong-profile
        expect_fail "wrong architecture rejected" duranium update install /testdata/artifacts/wrong-arch
        expect_fail "wrong hardware rejected" duranium update install /testdata/artifacts/wrong-hardware
        expect_fail "injected write failure rejected" env DURANIUM_TEST_FAIL_AT=write duranium update install /testdata/artifacts/b-v2
        expect_fail "injected read-back failure rejected" env DURANIUM_TEST_FAIL_AT=readback duranium update install /testdata/artifacts/b-v2

        expect_slot_status A GOOD
        expect_active A
        _a_after=$(sha256sum /dev/vda3 | awk '{print $1}')
        expect_eq "active A unchanged after rejected updates" "$_a_before" "$_a_after"
        expect_eq "no pending slot after failures" "none" "$(status_field pending)"
        seed_state_files

        # Real power-loss simulation: the updater has already recorded
        # update_in_progress and then the process dies mid-write.
        env DURANIUM_TEST_PARTIAL_WRITE_BYTES=1048576 DURANIUM_TEST_POWER_LOSS=1 \
            duranium update install /testdata/artifacts/b-v2 >/dev/null 2>&1
        _rc=$?
        if [ "$_rc" -eq 137 ] || [ "$_rc" -ne 0 ]; then
            pass "update process died during write (rc=$_rc)"
        else
            fail "power-loss injection did not terminate the updater"
        fi
        expect_contains "interrupted transaction recorded" /boot/duranium/global.meta "update_in_progress=B"
        expect_slot_status A GOOD
        expect_active A
        advance
        ;;
    1)
        expect_booted A
        expect_slot_status A GOOD
        expect_slot_status B BAD
        expect_active A
        expect_eq "reconciliation cleared pending" "none" "$(status_field pending)"
        expect_eq "B has no attempts" "0" "$(slot_field B boot_attempts_remaining)"
        seed_state_files
        finish
        ;;
    *)
        fail "unknown failure phase $1"
        ;;
    esac
}
