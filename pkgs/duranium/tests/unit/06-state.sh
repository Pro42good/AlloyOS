#!/bin/sh
# Persistent STATE: classification, schema, migrations, rollback safety.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init state
printf 'setting-v1\n' > "$T/root/state/etc/alloy/settings.conf"
mkdir -p "$T/root/state/home/user"
printf 'user-data\n' > "$T/root/state/home/user/file.txt"

cat > "$T/migrations/1-to-2.conf" <<'EOF'
from=1
to=2
kind=backward-compatible
EOF
cat > "$T/migrations/1-to-2.sh" <<'EOF'
#!/bin/sh
set -eu
mkdir -p "$DURANIUM_STATE_MNT/etc/alloy/v2"
cp "$DURANIUM_STATE_MNT/etc/alloy/settings.conf" "$DURANIUM_STATE_MNT/etc/alloy/v2/settings.conf"
EOF
chmod +x "$T/migrations/1-to-2.sh"

# A understands schema 1.
assert_eq "initial state schema" "1" "$(dk state schema)"

make_slot_pending B 2.0 B-v2 2 A
assert_eq "boot pending B requiring schema 2" "B" "$(sim_boot)"
assert_ok "safe schema 1 -> 2 migration" dk state migrate B
assert_eq "state schema is now 2" "2" "$(dk state schema)"
assert_file "old schema path preserved" "$T/root/state/etc/alloy/settings.conf"
assert_file "new schema path added" "$T/root/state/etc/alloy/v2/settings.conf"
assert_eq "old settings content intact" "setting-v1" "$(cat "$T/root/state/etc/alloy/settings.conf")"
_setting_v2=$(cat "$T/root/state/etc/alloy/v2/settings.conf")
assert_eq "new settings copy intact" "setting-v1" "$_setting_v2"
if ls "$T/root/state/duranium/backups"/before-1-to-2-*.tar >/dev/null 2>&1; then
    ok
else
    fail "migration backup was not created"
fi
assert_ok "B remains pending after migration" dk slot show B
assert_slot_status "B remains PENDING until mark-good" B PENDING

# Rollback to old slot A: newer schema is tolerated because the migration was
# additive/backward-compatible. A reads its old data.
assert_ok "mark B BAD to simulate rollback" dk mark-bad B
assert_eq "boot fallback A" "A" "$(sim_boot)"
assert_ok "old slot tolerates newer state schema" dk state migrate A
assert_eq "state schema remains 2 on rollback" "2" "$(dk state schema)"
assert_eq "old slot still reads old settings" "setting-v1" "$(cat "$T/root/state/etc/alloy/settings.conf")"
assert_eq "user state survives rollback" "user-data" "$(cat "$T/root/state/home/user/file.txt")"

# Failed migration aborts activation.
test_init state-failed
printf 'setting-v1\n' > "$T/root/state/etc/alloy/settings.conf"
cat > "$T/migrations/1-to-2.conf" <<'EOF'
from=1
to=2
kind=backward-compatible
EOF
cat > "$T/migrations/1-to-2.sh" <<'EOF'
#!/bin/sh
echo "intentional migration failure" >&2
exit 1
EOF
chmod +x "$T/migrations/1-to-2.sh"
make_slot_pending B 2.0 B-v2 2 A
assert_eq "boot pending B before failed migration" "B" "$(sim_boot)"
assert_fail "failed migration aborts activation" dk state migrate B
assert_slot_status "failed migration marks B BAD" B BAD
assert_eq "failed migration leaves old schema" "1" "$(dk state schema)"
assert_eq "failed migration keeps old data" "setting-v1" "$(cat "$T/root/state/etc/alloy/settings.conf")"

# Irreversible migration is rejected while a rollback slot is expected.
test_init state-irreversible
printf 'setting-v1\n' > "$T/root/state/etc/alloy/settings.conf"
cat > "$T/migrations/1-to-2.conf" <<'EOF'
from=1
to=2
kind=irreversible
EOF
cat > "$T/migrations/1-to-2.sh" <<'EOF'
#!/bin/sh
touch "$DURANIUM_STATE_MNT/should-not-exist"
EOF
chmod +x "$T/migrations/1-to-2.sh"
make_slot_pending B 2.0 B-v2 2 A
assert_eq "boot pending B before irreversible migration" "B" "$(sim_boot)"
assert_fail "irreversible migration rejected" dk state migrate B
assert_slot_status "irreversible migration marks B BAD" B BAD
assert_eq "irreversible migration did not run" "1" "$(dk state schema)"
assert_no_file "irreversible migration side effect absent" "$T/root/state/should-not-exist"

test_done
