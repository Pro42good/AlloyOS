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
assert_ok "OS confirms the boot" dk boot-confirm
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

# A corrupt STATE schema file must fail the install closed, not silently
# bypass the schema checks.
test_init update-schema-corrupt
make_key
make_artifact "$T/art-s" 2.0 B-s2 dev aarch64 qemu-aarch64-virt 2
printf 'garbage\n' > "$T/root/state/duranium/schema"
assert_fail "corrupt STATE schema refuses install" dk update install "$T/art-s"
assert_slot_status "B not activated on corrupt schema" B UNKNOWN
assert_eq "A still active after corrupt schema" "A" "$(fake_boot)"

# gzip payload end-to-end: materialization, size/hash verification, install.
test_init update-gzip
make_key
make_artifact "$T/art-g" 2.0 G-v2
gzip -c "$T/art-g/system.img" > "$T/art-g/system.img.gz"
rm -f "$T/art-g/system.img"
awk '{ if ($0 ~ /^system_image=/) print "system_image=system.img.gz";
       else if ($0 ~ /^system_image_compression=/) print "system_image_compression=gzip";
       else print }' "$T/art-g/manifest.txt" > "$T/art-g/manifest.txt.new"
mv "$T/art-g/manifest.txt.new" "$T/art-g/manifest.txt"
"$DURANIUM_BIN" manifest sign "$T/art-g" "$T/keys/$KEY_ID.priv.pem" >/dev/null
assert_eq "boot GOOD A (gzip)" "A" "$(sim_boot)"
assert_ok "gzip artifact installs" dk update install "$T/art-g"
assert_slot_status "B PENDING from gzip payload" B PENDING
assert_eq "B image hash matches manifest" \
    "$(sed -n 's/^system_image_sha256=//p' "$T/art-g/manifest.txt")" \
    "$(sha256sum "$T/root/slots/B.img" | awk '{print $1}')"

# Update lock: a live holder must block a second updater. Skipped on hosts
# without /proc.
test_init update-lock
make_key
make_artifact "$T/art-l" 2.0 L-v2
assert_eq "boot GOOD A (lock)" "A" "$(sim_boot)"
mkdir -p "$T/run/update.lock"
printf '%s\n' "1" > "$T/run/update.lock/pid"
if [ -d /proc/1 ]; then
    assert_fail "live lock holder blocks second update" dk update install "$T/art-l"
    assert_slot_status "B untouched while locked" B UNKNOWN
fi
rm -rf "$T/run/update.lock"

# A dead holder's lock is stolen; a stale lock must not wedge updates.
test_init update-lock-stale
make_key
make_artifact "$T/art-s" 2.0 S-v2
assert_eq "boot GOOD A (stale lock)" "A" "$(sim_boot)"
mkdir -p "$T/run/update.lock"
printf '%s\n' "999999" > "$T/run/update.lock/pid"
assert_ok "dead-holder lock is stolen" dk update install "$T/art-s"
assert_slot_status "B PENDING after stealing stale lock" B PENDING

# The updater must refuse to write a system image over STATE even when the
# slot config collides with it (in recovery STATE is unmounted and the
# mounted-device check cannot catch this).
test_init update-target-collision
make_key
make_artifact "$T/art-c" 2.0 C-v2
assert_eq "boot GOOD A (collision)" "A" "$(sim_boot)"
assert_fail "writing over the STATE device is refused" \
    dk_env "DURANIUM_SLOT_B_DEV=$DURANIUM_STATE_DEV" update install "$T/art-c"

test_done
