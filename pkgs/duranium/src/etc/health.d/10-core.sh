#!/bin/sh
# Built-in health check sample. The Duranium CLI already checks root ro,
# STATE, core readiness and expected services; this demonstrates the health.d
# extension point.

if [ -n "${DURANIUM_HEALTH_EXTRA_MARKER:-}" ]; then
    [ -e "$DURANIUM_HEALTH_EXTRA_MARKER" ] || {
        printf 'duranium health: missing marker %s\n' "$DURANIUM_HEALTH_EXTRA_MARKER" >&2
        exit 1
    }
fi
exit 0
