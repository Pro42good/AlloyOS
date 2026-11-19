#!/bin/sh
# Example additive, rollback-safe migration: duplicate the old settings file
# into a v2 namespace while leaving the schema-1 path untouched. Slot A can
# still read the old path after a rollback.
set -eu

: "${DURANIUM_STATE_MNT:?DURANIUM_STATE_MNT is required}"

if [ -f "$DURANIUM_STATE_MNT/etc/alloy/settings.conf" ]; then
    mkdir -p "$DURANIUM_STATE_MNT/etc/alloy/v2"
    cp "$DURANIUM_STATE_MNT/etc/alloy/settings.conf" \
       "$DURANIUM_STATE_MNT/etc/alloy/v2/settings.conf"
fi
