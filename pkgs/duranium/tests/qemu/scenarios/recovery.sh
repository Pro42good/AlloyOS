#!/bin/sh
# Recovery scenario: the host deliberately destroys SYSTEM_A before the first
# boot (SYSTEM_B starts UNKNOWN). Recovery must boot, inspect, reinstall A from
# a signed artifact, and preserve STATE. A then boots, migrates STATE to schema
# 2, and is explicitly marked GOOD.

scenario_step() {
    case "$1" in
    0)
        expect_file "recovery marker" /run/duranium/recovery
        expect_file "STATE is mounted in recovery" /state/duranium/schema
        expect_eq "seed settings visible in recovery" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
        expect_eq "seed user visible in recovery" "seed-user" "$(cat /state/home/user/seed.txt 2>/dev/null)"
        expect_slot_status A BAD
        expect_eq "B is not GOOD" "UNKNOWN" "$(slot_field B status)"
        run_or_fail "repair boot metadata" duranium recovery repair-boot
        run_or_fail "reinstall A from signed artifact" \
            duranium recovery reinstall --slot A --artifact /testdata/artifacts/a-v3
        expect_slot_status A PENDING
        expect_eq "STATE survives reinstall" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
        expect_eq "user STATE survives reinstall" "seed-user" "$(cat /state/home/user/seed.txt 2>/dev/null)"
        advance
        ;;
    1)
        expect_booted A
        expect_slot_status A PENDING
        expect_eq "STATE schema migrated to 2" "2" "$(duranium state schema)"
        expect_eq "STATE settings survive boot" "seed-setting" "$(cat /state/etc/alloy/settings.conf 2>/dev/null)"
        expect_eq "STATE user data survives boot" "seed-user" "$(cat /state/home/user/seed.txt 2>/dev/null)"
        run_or_fail "mark A GOOD after recovery" duranium mark-good A
        expect_slot_status A GOOD
        expect_active A
        finish
        ;;
    *)
        fail "unknown recovery phase $1"
        ;;
    esac
}
