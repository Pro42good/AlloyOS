#!/bin/sh
# Policy: production update logic must not mutate the running system with apk
# and must use SHA-256 + Ed25519 rather than custom cryptography.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

if grep -R -n -E '(^|[;&|[:space:]])apk[[:space:]]+(upgrade|add|del)' \
    "$REPO/src/bin" "$REPO/src/lib" "$REPO/src/root" "$REPO/src/recovery" \
    > "$DURANIUM_TEST_TMP/policy-apk.out" 2>/dev/null; then
    fail "runtime code invokes apk to mutate the live system"
else
    ok
fi

if grep -R -n -E '(^|[;&|[:space:]])(curl|wget)[[:space:]]' \
    "$REPO/src/bin" "$REPO/src/lib" \
    > "$DURANIUM_TEST_TMP/policy-net.out" 2>/dev/null; then
    fail "runtime updater contains a network download path"
else
    ok
fi

if grep -q 'openssl pkeyutl -verify -rawin' "$REPO/src/lib/manifest.sh" &&
   grep -q 'dur_sha256' "$REPO/src/lib/manifest.sh"; then
    ok
else
    fail "manifest verification does not use SHA-256 and Ed25519"
fi

test_done
