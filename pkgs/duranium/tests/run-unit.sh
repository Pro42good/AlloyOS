#!/bin/sh
# Duranium unit test runner.
# On non-Linux hosts the tests run inside the already-installed Alpine aarch64
# container for BusyBox/Alpine parity. On Linux they run directly.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)

run_local() {
    TEST_TMP="$REPO/tests/.tmp/run-$$"
    rm -rf "$TEST_TMP"
    mkdir -p "$TEST_TMP"
    export DURANIUM_TEST_TMP="$TEST_TMP"
    export DURANIUM_TEST_REPO="$REPO"

    passed=0
    failed=0
    for t in "$REPO"/tests/unit/[0-9]*.sh; do
        [ -r "$t" ] || continue
        printf '\n== %s ==\n' "$(basename "$t")"
        if DURANIUM_TEST_TMP="$TEST_TMP" sh "$t"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done
    printf '\nUNIT SUMMARY: %s passed, %s failed\n' "$passed" "$failed"
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
    rm -rf "$TEST_TMP"
    return 0
}

if [ "${DURANIUM_IN_CONTAINER:-0}" = "1" ]; then
    run_local
    exit $?
fi

case "$(uname -s)" in
    Linux)
        if command -v sha256sum >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
            run_local
            exit $?
        fi
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    printf 'unit tests require Linux with openssl, or Docker\n' >&2
    exit 1
fi

PKG_DIR=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
docker run --rm -v "$PKG_DIR:/work" -w /work -e DURANIUM_IN_CONTAINER=1 \
    --platform linux/arm64 alpine:3.20 sh -c '
        apk add -q openssl >/dev/null 2>&1
        cd /work
        exec sh /work/tests/run-unit.sh
    '
