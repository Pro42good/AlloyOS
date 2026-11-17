#!/bin/sh
# Corrupted pending boot artifact: B's kernel is destroyed after a valid
# update. systemd-boot boot counting must exhaust B and fall back to A.
#
# This is distinct from acceptance's root-filesystem corruption: here the
# per-slot kernel itself cannot be loaded.

scenario_step() {
    case "$1" in
    0)
        expect_booted A
        expect_slot_status A GOOD
        expect_active A
        run_or_fail "install valid update into B" duranium update install /testdata/artifacts/b-v2
        expect_slot_status B PENDING
        expect_contains "B pending entry present" /boot/loader/entries/duranium-b+3.conf "Alloy B"
        if dd if=/dev/zero of=/boot/duranium/boot/B/vmlinuz bs=1M count=1 conv=notrunc 2>/dev/null; then
            sync
            pass "corrupted B kernel"
        else
            fail "could not corrupt B kernel"
        fi
        advance
        ;;
    1)
        expect_booted A
        expect_slot_status A GOOD
        expect_slot_status B BAD
        expect_active A
        expect_eq "pending cleared after corrupted-boot fallback" "none" "$(status_field pending)"
        expect_eq "B attempts exhausted" "0" "$(slot_field B boot_attempts_remaining)"
        seed_state_files
        expect_no_file "B counter entry removed" /boot/loader/entries/duranium-b+3.conf
        finish
        ;;
    *)
        fail "unknown corrupt-boot phase $1"
        ;;
    esac
}
