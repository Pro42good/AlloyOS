#!/bin/sh
# Mixed recovery scenario:
#   * SYSTEM_B is broken from the start, but SYSTEM_A still boots.
#   * A then asks the host to destroy SYSTEM_A.
#   * Recovery must boot with both normal slots unusable, reinstall A, and
#     preserve STATE.

scenario_step() {
    case "$1" in
    0)
        expect_booted A
        expect_slot_status A GOOD
        expect_eq "B is not bootable" "UNKNOWN" "$(slot_field B status)"
        seed_state_files
        request_corrupt A
        ;;
    1)
        expect_file "recovery marker" /run/duranium/recovery
        expect_file "STATE is mounted in recovery" /state/duranium/schema
        expect_slot_status A BAD
        expect_eq "B is not GOOD" "UNKNOWN" "$(slot_field B status)"
        expect_eq "seed settings visible in recovery" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
        run_or_fail "repair boot metadata" duranium recovery repair-boot
        run_or_fail "reinstall A preserving STATE" \
            duranium recovery reinstall --slot A --artifact /testdata/artifacts/a-v3
        expect_slot_status A PENDING
        expect_eq "STATE survives reinstall" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
        advance
        ;;
    2)
        expect_booted A
        expect_slot_status A PENDING
        expect_eq "STATE schema is 2" "2" "$(duranium state schema)"
        expect_eq "STATE user data survives" "seed-user" "$(cat /state/home/user/seed.txt 2>/dev/null)"
        run_or_fail "mark A GOOD after recovery" duranium mark-good A
        expect_slot_status A GOOD
        expect_active A
        finish
        ;;
    *)
        fail "unknown mixed recovery phase $1"
        ;;
    esac
}
