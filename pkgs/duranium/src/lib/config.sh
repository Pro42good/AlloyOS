#!/bin/sh
# Duranium configuration loader.
#
# All values may be overridden by environment variables. The on-disk config is
# a shell fragment using ": ${VAR:=default}" assignments; it is trusted
# image-owned configuration, never user-supplied metadata.

: "${DURANIUM_CONFIG:=/etc/duranium/duranium.conf}"
if [ -r "$DURANIUM_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$DURANIUM_CONFIG"
fi

: "${DURANIUM_BACKEND:=block}"
: "${DURANIUM_BOOTLOADER:=systemd-boot}"
: "${DURANIUM_BOOT_MNT:=/boot}"
: "${DURANIUM_STATE_MNT:=/state}"
: "${DURANIUM_RECOVERY_MNT:=/recovery}"
: "${DURANIUM_NEWROOT:=/sysroot}"
: "${DURANIUM_RUN:=/run/duranium}"
: "${DURANIUM_KEYS_DIR:=/etc/duranium/keys}"
: "${DURANIUM_STATE_CONF:=/etc/duranium/state.conf}"
: "${DURANIUM_MIGRATIONS_DIR:=/usr/lib/duranium/migrations}"
: "${DURANIUM_MAX_BOOT_ATTEMPTS:=3}"
# Validate: 0 makes every pending slot instantly BAD; > 20 breaks slot
# metadata validation and wedges boot-record. Fall back to the default.
case "$DURANIUM_MAX_BOOT_ATTEMPTS" in
    ''|*[!0-9]*) dur_warn "DURANIUM_MAX_BOOT_ATTEMPTS='$DURANIUM_MAX_BOOT_ATTEMPTS' is not a number; using 3"
        DURANIUM_MAX_BOOT_ATTEMPTS=3 ;;
esac
if [ "$DURANIUM_MAX_BOOT_ATTEMPTS" -lt 1 ] || [ "$DURANIUM_MAX_BOOT_ATTEMPTS" -gt 20 ]; then
    dur_warn "DURANIUM_MAX_BOOT_ATTEMPTS=$DURANIUM_MAX_BOOT_ATTEMPTS is out of range (1-20); using 3"
    DURANIUM_MAX_BOOT_ATTEMPTS=3
fi
: "${DURANIUM_CONSOLE:=console=ttyAMA0}"
: "${DURANIUM_EXTRA_CMDLINE:=}"
: "${DURANIUM_DEV_OVERRIDE:=0}"
: "${DURANIUM_FSCK:=1}"
: "${DURANIUM_VERIFY_ROOT_ON_BOOT:=0}"
: "${DURANIUM_TEST_MODE:=0}"
: "${DURANIUM_HEALTH_CORE_MARKER:=/run/alloy/core-ready}"
: "${DURANIUM_HEALTH_REQUIRE_ROOT_RO:=1}"
: "${DURANIUM_HEALTH_REQUIRE_STATE:=1}"
: "${DURANIUM_HEALTH_REQUIRE_CORE:=1}"
# Sign-in gate (stage 2 of the boot-confirmation handshake). V1 default is
# off; the Alloy desktop sets this to 1 so a pending slot is confirmed only
# after the user session came up ("duranium session-confirm").
: "${DURANIUM_REQUIRE_SESSION:=0}"
: "${DURANIUM_TEST_PARTIAL_WRITE_BYTES:=}"
: "${DURANIUM_TEST_FAIL_AT:=}"
: "${DURANIUM_TEST_POWER_LOSS:=0}"
: "${DURANIUM_TEST_SKIP_HEALTH:=0}"
: "${DURANIUM_TEST_ACCEPT_IRREVERSIBLE:=0}"

: "${DURANIUM_ARCH:=}"
if [ -z "$DURANIUM_ARCH" ]; then
    DURANIUM_ARCH=$(uname -m 2>/dev/null || printf 'unknown\n')
fi

: "${DURANIUM_PROFILE:=}"
if [ -z "$DURANIUM_PROFILE" ]; then
    if [ -r /etc/duranium/profile ]; then
        DURANIUM_PROFILE=$(tr -d '\n' < /etc/duranium/profile)
    else
        DURANIUM_PROFILE=prod
    fi
fi

: "${DURANIUM_HARDWARE_TARGET:=}"
if [ -z "$DURANIUM_HARDWARE_TARGET" ]; then
    if [ -r /etc/duranium/hardware-target ]; then
        DURANIUM_HARDWARE_TARGET=$(tr -d '\n' < /etc/duranium/hardware-target)
    else
        DURANIUM_HARDWARE_TARGET=generic-aarch64
    fi
fi

: "${DURANIUM_STATE_SCHEMA:=}"
if [ -z "$DURANIUM_STATE_SCHEMA" ] && [ -r /etc/duranium/state-schema ]; then
    DURANIUM_STATE_SCHEMA=$(tr -d '\n' < /etc/duranium/state-schema)
fi
: "${DURANIUM_STATE_SCHEMA:=1}"

: "${DURANIUM_SLOT_A_DEV:=}"
: "${DURANIUM_SLOT_B_DEV:=}"
: "${DURANIUM_STATE_DEV:=}"
: "${DURANIUM_RECOVERY_DEV:=}"
: "${DURANIUM_BOOT_DEV:=}"
: "${DURANIUM_BOOT_PARTLABEL:=duranium-boot}"
: "${DURANIUM_RECOVERY_PARTLABEL:=duranium-recovery}"
: "${DURANIUM_SLOT_A_PARTLABEL:=duranium-system-a}"
: "${DURANIUM_SLOT_B_PARTLABEL:=duranium-system-b}"
: "${DURANIUM_STATE_PARTLABEL:=duranium-state}"

DURANIUM_META_DIR="${DURANIUM_META_DIR:-$DURANIUM_BOOT_MNT/duranium}"
DURANIUM_ENTRIES_DIR="${DURANIUM_ENTRIES_DIR:-$DURANIUM_BOOT_MNT/loader/entries}"
DURANIUM_BOOT_FILES_DIR="${DURANIUM_BOOT_FILES_DIR:-$DURANIUM_META_DIR/boot}"
DURANIUM_RECOVERY_ROOT="${DURANIUM_RECOVERY_ROOT:-$DURANIUM_RECOVERY_MNT}"

# The run directory is tmpfs in production and a temp tree in tests. Do not
# fail hard if it is not writable yet (the initramfs creates it explicitly).
if [ ! -d "$DURANIUM_RUN" ]; then
    mkdir -p "$DURANIUM_RUN" 2>/dev/null || true
fi
if [ ! -d "$DURANIUM_RUN" ] && [ "$DURANIUM_BACKEND" = "dir" ]; then
    mkdir -p "$DURANIUM_RUN" 2>/dev/null || true
fi
DURANIUM_TMP="${DURANIUM_TMP:-$DURANIUM_RUN/tmp.$$}"
mkdir -p "$DURANIUM_TMP" 2>/dev/null || true

export DURANIUM_BACKEND DURANIUM_BOOTLOADER DURANIUM_BOOT_MNT DURANIUM_STATE_MNT
export DURANIUM_RECOVERY_MNT DURANIUM_RUN DURANIUM_KEYS_DIR DURANIUM_STATE_CONF
export DURANIUM_MIGRATIONS_DIR DURANIUM_MAX_BOOT_ATTEMPTS DURANIUM_CONSOLE
export DURANIUM_EXTRA_CMDLINE DURANIUM_DEV_OVERRIDE DURANIUM_FSCK
export DURANIUM_ARCH DURANIUM_PROFILE DURANIUM_HARDWARE_TARGET DURANIUM_STATE_SCHEMA
export DURANIUM_META_DIR DURANIUM_ENTRIES_DIR DURANIUM_BOOT_FILES_DIR
export DURANIUM_TEST_MODE DURANIUM_TMP DURANIUM_REQUIRE_SESSION
export DURANIUM_HEALTH_CORE_MARKER DURANIUM_HEALTH_REQUIRE_ROOT_RO
export DURANIUM_HEALTH_REQUIRE_STATE DURANIUM_HEALTH_REQUIRE_CORE
export DURANIUM_VERIFY_ROOT_ON_BOOT
