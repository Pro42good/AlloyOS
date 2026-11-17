#!/bin/sh
# Metadata: persistence, redundancy, corruption safety, strict validation.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init metadata

assert_slot_status "A starts GOOD" A GOOD
assert_slot_status "B starts UNKNOWN" B UNKNOWN
assert_contains "global active A" "$T/root/boot/duranium/global.meta" "active_slot=A"
assert_contains "slot A has checksum" "$T/root/boot/duranium/slots/A.meta" "checksum="

# Persistence across separate CLI invocations is implicit in every dk call.
assert_eq "A version survives" "1.0" "$(dk slot show A | sed -n 's/.*version=\([^ ]*\).*/\1/p')"

# Backup fallback: corrupt the primary, keep a valid backup.
cp "$T/root/boot/duranium/slots/A.meta" "$T/root/boot/duranium/slots/A.meta.bak"
printf 'this-is-not-metadata\n' >> "$T/root/boot/duranium/slots/A.meta"
assert_ok "A primary corruption falls back to backup" dk slot show A
dk slot show A > "$T/a.out" 2>/dev/null || true
assert_contains "A backup source reported" "$T/a.out" "source=backup"
cp "$T/root/boot/duranium/slots/A.meta.bak" "$T/root/boot/duranium/slots/A.meta"

# Unknown field on B (no valid backup) is rejected.
rm -f "$T/root/boot/duranium/slots/B.meta.bak"
cp "$T/root/boot/duranium/slots/B.meta" "$T/b.meta.good"
printf 'surprise_field=1\n' >> "$T/root/boot/duranium/slots/B.meta"
assert_fail "unknown metadata field rejected" dk slot show B
cp "$T/b.meta.good" "$T/root/boot/duranium/slots/B.meta"

# Checksum corruption is rejected.
sed 's/^checksum=.*/checksum=0000000000000000000000000000000000000000000000000000000000000000/' "$T/root/boot/duranium/slots/B.meta" > "$T/root/boot/duranium/slots/B.meta.bad"
mv "$T/root/boot/duranium/slots/B.meta.bad" "$T/root/boot/duranium/slots/B.meta"
assert_fail "bad checksum rejected" dk slot show B
cp "$T/b.meta.good" "$T/root/boot/duranium/slots/B.meta"

# One slot being completely corrupt must not destroy the other slot's metadata.
printf 'garbage\n' > "$T/root/boot/duranium/slots/B.meta"
printf 'garbage\n' > "$T/root/boot/duranium/slots/B.meta.bak"
assert_fail "fully corrupt B metadata is rejected" dk slot show B
assert_ok "A metadata still readable" dk slot show A
dk slot show A > "$T/a2.out" 2>/dev/null || true
assert_contains "A still GOOD" "$T/a2.out" "status=GOOD"
cp "$T/b.meta.good" "$T/root/boot/duranium/slots/B.meta"
rm -f "$T/root/boot/duranium/slots/B.meta.bak"

# Invalid mandatory values are rejected by the writer/parser.
assert_fail "invalid status rejected" dk admin init-slot B status=BOGUS
assert_fail "invalid attempts rejected" dk admin init-slot B boot_attempts_remaining=99
assert_fail "invalid profile rejected" dk admin init-slot B profile=turbo
assert_fail "unknown mandatory field rejected" dk admin init-slot B nonsense=1

assert_slot_status "B remains UNKNOWN after rejected writes" B UNKNOWN

test_done
