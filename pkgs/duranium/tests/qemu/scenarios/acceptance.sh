#!/bin/sh
# Acceptance scenario: clean A, install B, boot B pending, explicit mark-good,
# update back to A, then a pending B whose root image is destroyed. The final
# boot must fall back to A with STATE intact.
#
# Every step ends with advance/done/fail. The host boots the VM again after a
# poweroff. Broken-slot boots never reach this agent.

scenario_step() {
    case "$1" in
    0)
        expect_booted A
        expect_slot_status A GOOD
        expect_active A
        if root_is_ro; then pass "root is mounted read-only"; else fail "root is not read-only"; fi
        if state_is_mounted; then pass "STATE is mounted"; else fail "STATE is not mounted"; fi
        expect_file "clean A marker" /etc/alloy-version
        write_user_state
        write_ephemeral
        _a_before=$(sha256sum /dev/vda3 | awk '{print $1}')
        run_or_fail "install signed update into B" duranium update install /testdata/artifacts/b-v2
        expect_slot_status B PENDING
        expect_active A
        expect_pending B
        _a_after=$(sha256sum /dev/vda3 | awk '{print $1}')
        expect_eq "active A device unchanged by update" "$_a_before" "$_a_after"
        expect_contains "B boot counter present" /boot/loader/entries/duranium-b+3.conf "Alloy B"
        check_user_state
        advance
        ;;
    1)
        expect_booted B
        expect_slot_status B PENDING
        expect_active A
        expect_eq "B attempts after first pending boot" "2" "$(slot_field B boot_attempts_remaining)"
        if root_is_ro; then pass "B root read-only"; else fail "B root is writable"; fi
        if state_is_mounted; then pass "STATE mounted on B"; else fail "STATE missing on B"; fi
        check_user_state
        check_ephemeral_gone
        # Deliberately do not mark good; the slot must remain pending.
        advance
        ;;
    2)
        expect_booted B
        expect_slot_status B PENDING
        expect_active A
        expect_eq "B attempts after second pending boot" "1" "$(slot_field B boot_attempts_remaining)"
        check_user_state
        run_or_fail "explicitly mark B GOOD" duranium mark-good B
        expect_slot_status B GOOD
        expect_active B
        expect_eq "fallback is A" "A" "$(status_field fallback)"
        expect_pending
        check_user_state
        advance
        ;;
    3)
        expect_booted B
        expect_slot_status B GOOD
        expect_active B
        _b_before=$(sha256sum /dev/vda4 | awk '{print $1}')
        run_or_fail "install update into inactive A" duranium update install /testdata/artifacts/a-v3
        expect_slot_status A PENDING
        expect_active B
        expect_pending A
        _b_after=$(sha256sum /dev/vda4 | awk '{print $1}')
        expect_eq "active B device unchanged by update" "$_b_before" "$_b_after"
        expect_contains "A boot counter present" /boot/loader/entries/duranium-a+3.conf "Alloy A"
        check_user_state
        advance
        ;;
    4)
        expect_booted A
        expect_slot_status A PENDING
        expect_active B
        check_user_state
        run_or_fail "mark A GOOD" duranium mark-good A
        expect_slot_status A GOOD
        expect_active A
        expect_eq "fallback is B" "B" "$(status_field fallback)"
        check_user_state

        # Install into B, then destroy B's root filesystem before rebooting.
        run_or_fail "install broken candidate into B" duranium update install /testdata/artifacts/b-v2
        expect_slot_status B PENDING
        expect_contains "B pending counter" /boot/loader/entries/duranium-b+3.conf "Alloy B"
        if dd if=/dev/zero of=/dev/vda4 bs=1M count=1 conv=notrunc 2>/dev/null; then
            sync
            pass "destroyed B root superblock"
        else
            fail "could not destroy B root"
        fi
        advance
        ;;
    5)
        expect_booted A
        expect_slot_status A GOOD
        expect_slot_status B BAD
        expect_active A
        expect_eq "pending cleared after rollback" "none" "$(status_field pending)"
        expect_eq "B attempts exhausted" "0" "$(slot_field B boot_attempts_remaining)"
        expect_no_file "B counter entry removed" /boot/loader/entries/duranium-b+3.conf
        check_user_state
        expect_eq "A version after update" "A-v3" "$(cat /etc/alloy-version 2>/dev/null | sed 's/^version=//')"
        finish
        ;;
    *)
        fail "unknown acceptance phase $1"
        ;;
    esac
}
