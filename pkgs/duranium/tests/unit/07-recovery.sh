#!/bin/sh
# Recovery: independent CLI, reinstall, metadata repair, STATE preservation.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init recovery
make_key
make_artifact "$T/art-a" 4.0 A-v4
printf 'state-must-survive\n' > "$T/root/state/etc/alloy/settings.conf"
mkdir -p "$T/root/state/home/user"
printf 'user-must-survive\n' > "$T/root/state/home/user/file"

# Both normal slots are unusable.
dk mark-bad A >/dev/null 2>&1 || true
dk mark-bad B >/dev/null 2>&1 || true
assert_slot_status "A is BAD" A BAD
assert_slot_status "B is BAD" B BAD

assert_ok "recovery status" dk_env "DURANIUM_RECOVERY=1" recovery status
assert_ok "recovery inspect" dk_env "DURANIUM_RECOVERY=1" recovery inspect
assert_ok "recovery repair boot metadata" dk_env "DURANIUM_RECOVERY=1" recovery repair-boot

assert_ok "recovery reinstall A preserving STATE" \
    dk_env "DURANIUM_RECOVERY=1" recovery reinstall --slot A --artifact "$T/art-a"
assert_slot_status "A is PENDING after recovery reinstall" A PENDING
assert_eq "STATE settings survive reinstall" "state-must-survive" \
    "$(cat "$T/root/state/etc/alloy/settings.conf")"
assert_eq "STATE user file survives reinstall" "user-must-survive" \
    "$(cat "$T/root/state/home/user/file")"
assert_file "A has recovery-installed kernel" "$T/root/boot/duranium/boot/A/vmlinuz"
assert_fail "recovery select BAD slot is refused" dk_env "DURANIUM_RECOVERY=1" recovery select B

assert_eq "A boots after recovery reinstall" "A" "$(sim_boot)"
assert_ok "OS confirms the boot" dk boot-confirm
assert_ok "A can be marked GOOD after reinstall" dk mark-good A
assert_slot_status "A is GOOD" A GOOD
assert_eq "STATE survives boot and mark-good" "state-must-survive" \
    "$(cat "$T/root/state/etc/alloy/settings.conf")"

# Recovery can explicitly change active/fallback.
assert_ok "recovery select A" dk_env "DURANIUM_RECOVERY=1" recovery select A

# OS reinstall must not delete STATE.
assert_ok "factory reset OS only" dk_env "DURANIUM_RECOVERY=1" recovery factory-reset --mode os --yes
assert_slot_status "A is UNKNOWN after OS reset" A UNKNOWN
assert_slot_status "B is UNKNOWN after OS reset" B UNKNOWN
assert_eq "OS reset preserves STATE" "state-must-survive" \
    "$(cat "$T/root/state/etc/alloy/settings.conf")"

# STATE wipe is explicit and separate.
assert_ok "factory reset STATE only" dk_env "DURANIUM_RECOVERY=1" recovery factory-reset --mode state --yes
assert_no_file "STATE file deleted by STATE reset" "$T/root/state/etc/alloy/settings.conf"
if [ -d "$T/root/state/etc/alloy" ] && [ -d "$T/root/state/duranium" ]; then ok; else
    fail "STATE layout not recreated after wipe"
fi

# Full reset is refused without --yes.
assert_fail "factory reset without --yes refused" dk_env "DURANIUM_RECOVERY=1" recovery factory-reset --mode full

# Recovery reinstall may target an artifact whose required schema is older
# than the current STATE: the runtime tolerates newer STATE on rollback, so
# blocking the reinstall would make the only surviving artifact unusable.
test_init recovery-schema-downgrade
make_key
make_artifact "$T/art-old" 1.0 OLD-v1
printf 'downgrade-state\n' > "$T/root/state/etc/alloy/settings.conf"
printf '2\n' > "$T/root/state/duranium/schema"
assert_ok "older-schema artifact reinstalls in recovery" \
    dk_env "DURANIUM_RECOVERY=1" recovery reinstall --slot A --artifact "$T/art-old"
assert_slot_status "A PENDING after older-schema reinstall" A PENDING
assert_eq "STATE survives older-schema reinstall" "downgrade-state" \
    "$(cat "$T/root/state/etc/alloy/settings.conf")"

# --force is a recovery decision, and it is only meaningful for a slot that
# can be re-armed: BAD/UNKNOWN slots get no boot entry at all.
test_init recovery-select-force
assert_fail "force-select of an UNKNOWN slot is refused" dk slot select B --force
make_slot_pending B 2.0 B-v2 1 A
assert_ok "force-select re-arms a pending slot" dk slot select B --force
assert_slot_status "B PENDING after force-select" B PENDING
assert_slot_field "attempts re-armed" B boot_attempts_remaining 3

test_done
