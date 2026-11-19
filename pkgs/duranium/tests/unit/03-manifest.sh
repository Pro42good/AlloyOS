#!/bin/sh
# Manifest: strict format, Ed25519 signature, payload/boot hashes, compatibility.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init manifest
make_key
make_artifact "$T/art-good" 1.0 B-v2

assert_ok "correctly signed update verifies" dk manifest verify "$T/art-good"
assert_ok "update verify alias" dk update verify "$T/art-good"

# Modified payload.
cp -a "$T/art-good" "$T/art-payload"
printf 'x' >> "$T/art-payload/system.img"
assert_fail "modified payload rejected" dk manifest verify "$T/art-payload"

# Modified manifest (signature is over exact bytes).
cp -a "$T/art-good" "$T/art-manifest"
printf 'extra=1\n' >> "$T/art-manifest/manifest.txt"
assert_fail "modified manifest rejected" dk manifest verify "$T/art-manifest"

# Wrong signing key.
dk manifest keygen "$T/keys" wrong >/dev/null
cp -a "$T/art-good" "$T/art-wrongkey"
dk manifest sign "$T/art-wrongkey" "$T/keys/wrong.priv.pem" >/dev/null 2>&1 || true
assert_fail "wrong signing key rejected" dk manifest verify "$T/art-wrongkey"

# Untrusted key id, signed with a key that is not in the trusted directory.
cp -a "$T/art-good" "$T/art-untrusted"
sed 's/^key_id=.*/key_id=other/' "$T/art-untrusted/manifest.txt" > "$T/art-untrusted/manifest.txt.new"
mv "$T/art-untrusted/manifest.txt.new" "$T/art-untrusted/manifest.txt"
dk manifest keygen "$T/keys" other >/dev/null
dk manifest sign "$T/art-untrusted" "$T/keys/other.priv.pem" >/dev/null 2>&1 || true
assert_fail "untrusted key rejected" dk manifest verify "$T/art-untrusted"

# Wrong architecture.
make_artifact "$T/art-arch" 1.0 B-v2 dev x86_64 qemu-aarch64-virt 1
dk manifest sign "$T/art-arch" "$T/keys/$KEY_ID.priv.pem" >/dev/null
assert_fail "wrong architecture rejected" dk manifest verify "$T/art-arch"

# Wrong profile: dev system rejects lab without override, accepts with the
# explicit dev override, and prod never inherits the override.
make_artifact "$T/art-lab" 1.0 B-v2 lab aarch64 qemu-aarch64-virt 1
dk manifest sign "$T/art-lab" "$T/keys/$KEY_ID.priv.pem" >/dev/null
assert_fail "wrong profile rejected" dk manifest verify "$T/art-lab"
assert_ok "explicit dev profile override accepted" dk manifest verify "$T/art-lab" --allow-profile-mismatch
assert_fail "prod cannot use dev override" dk_env "DURANIUM_PROFILE=prod DURANIUM_DEV_OVERRIDE=1" \
    manifest verify "$T/art-lab" --allow-profile-mismatch

# Wrong hardware target.
make_artifact "$T/art-hw" 1.0 B-v2 dev aarch64 krane-mt8183 1
dk manifest sign "$T/art-hw" "$T/keys/$KEY_ID.priv.pem" >/dev/null
assert_fail "wrong hardware target rejected" dk manifest verify "$T/art-hw"

# Unsupported manifest version: the signer itself must refuse it.
cp -a "$T/art-good" "$T/art-version"
sed 's/^format_version=1/format_version=2/' "$T/art-version/manifest.txt" > "$T/art-version/manifest.txt.new"
mv "$T/art-version/manifest.txt.new" "$T/art-version/manifest.txt"
assert_fail "unsupported manifest version rejected" dk manifest sign "$T/art-version" "$T/keys/$KEY_ID.priv.pem"
assert_fail "unsupported manifest version verify rejected" dk manifest verify "$T/art-version"

# Field reordering is rejected even if re-signed.
cp -a "$T/art-good" "$T/art-order"
awk 'NR==3{line=$0; next} NR==4{print; print line; next} {print}' "$T/art-order/manifest.txt" > "$T/art-order/manifest.txt.new"
mv "$T/art-order/manifest.txt.new" "$T/art-order/manifest.txt"
assert_fail "non-canonical field order rejected" dk manifest sign "$T/art-order" "$T/keys/$KEY_ID.priv.pem"

test_done
