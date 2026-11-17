#!/bin/sh
# Backend abstraction.
#
# Duranium core never hardcodes /dev/vdaN. The backend maps logical areas to
# block devices so the same logic runs on QEMU, Krane, or a test directory.
#
#   block - real devices, resolved by GPT partition label or config
#   dir   - files/directories under DURANIUM_ROOT for unit tests
#
# The bootloader backend is separate (bootloader.sh).

backend_resolve_label() {
    local _explicit _label _name _part _uevent
    _label=$1
    _explicit=$2
    if [ -n "$_explicit" ]; then
        printf '%s\n' "$_explicit"
        return 0
    fi
    if [ -e "/dev/disk/by-partlabel/$_label" ]; then
        readlink -f "/dev/disk/by-partlabel/$_label"
        return 0
    fi
    for _uevent in /sys/class/block/*/uevent; do
        [ -r "$_uevent" ] || continue
        _part=$(sed -n 's/^PARTNAME=//p' "$_uevent" 2>/dev/null | head -n 1)
        [ "$_part" = "$_label" ] || continue
        _name=$(basename "$(dirname "$_uevent")")
        printf '/dev/%s\n' "$_name"
        return 0
    done
    return 1
}

backend_init() {
    case "$DURANIUM_BACKEND" in
        block)
            DURANIUM_SLOT_A_DEV=$(backend_resolve_label "$DURANIUM_SLOT_A_PARTLABEL" "$DURANIUM_SLOT_A_DEV") || {
                DURANIUM_LAST_ERROR="cannot find slot A device ($DURANIUM_SLOT_A_PARTLABEL)"
                return 1
            }
            DURANIUM_SLOT_B_DEV=$(backend_resolve_label "$DURANIUM_SLOT_B_PARTLABEL" "$DURANIUM_SLOT_B_DEV") || {
                DURANIUM_LAST_ERROR="cannot find slot B device ($DURANIUM_SLOT_B_PARTLABEL)"
                return 1
            }
            DURANIUM_STATE_DEV=$(backend_resolve_label "$DURANIUM_STATE_PARTLABEL" "$DURANIUM_STATE_DEV") || {
                DURANIUM_LAST_ERROR="cannot find state device ($DURANIUM_STATE_PARTLABEL)"
                return 1
            }
            DURANIUM_RECOVERY_DEV=$(backend_resolve_label "$DURANIUM_RECOVERY_PARTLABEL" "$DURANIUM_RECOVERY_DEV") || {
                DURANIUM_LAST_ERROR="cannot find recovery device ($DURANIUM_RECOVERY_PARTLABEL)"
                return 1
            }
            ;;
        dir)
            [ -n "$DURANIUM_SLOT_A_DEV" ] || { DURANIUM_LAST_ERROR="dir backend: slot A path unset"; return 1; }
            [ -n "$DURANIUM_SLOT_B_DEV" ] || { DURANIUM_LAST_ERROR="dir backend: slot B path unset"; return 1; }
            [ -n "$DURANIUM_STATE_DEV" ] || { DURANIUM_LAST_ERROR="dir backend: state path unset"; return 1; }
            ;;
        *)
            DURANIUM_LAST_ERROR="unknown backend: $DURANIUM_BACKEND"
            return 1
            ;;
    esac
    export DURANIUM_SLOT_A_DEV DURANIUM_SLOT_B_DEV DURANIUM_STATE_DEV DURANIUM_RECOVERY_DEV
    return 0
}

backend_slot_dev() {
    case "$1" in
        A) printf '%s\n' "$DURANIUM_SLOT_A_DEV" ;;
        B) printf '%s\n' "$DURANIUM_SLOT_B_DEV" ;;
        *) return 1 ;;
    esac
}

backend_part_size() {
    local _dev _name _sectors
    _dev=$1
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        if [ -e "$_dev" ]; then
            wc -c < "$_dev" | tr -d ' '
            return 0
        fi
        return 1
    fi
    _name=$(basename "$_dev")
    if [ -r "/sys/class/block/$_name/size" ]; then
        _sectors=$(tr -d '\n' < "/sys/class/block/$_name/size")
        printf '%s\n' "$((_sectors * 512))"
        return 0
    fi
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --getsize64 "$_dev"
        return 0
    fi
    return 1
}

backend_slot_size() {
    backend_part_size "$(backend_slot_dev "$1")"
}

backend_write_image() {
    local _dev _part_size _size _slot _src
    _slot=$1
    _src=$2
    _size=$3
    _dev=$(backend_slot_dev "$_slot") || return 1
    dur_is_uint "$_size" || { DURANIUM_LAST_ERROR="invalid image size"; return 1; }

    case "$DURANIUM_BACKEND" in
        dir)
            if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ -n "${DURANIUM_TEST_PARTIAL_WRITE_BYTES:-}" ]; then
                dur_is_uint "$DURANIUM_TEST_PARTIAL_WRITE_BYTES" || return 1
                head -c "$DURANIUM_TEST_PARTIAL_WRITE_BYTES" "$_src" > "$_dev" || return 1
                sync 2>/dev/null || true
                if [ "${DURANIUM_TEST_POWER_LOSS:-0}" = "1" ]; then
                    exit 137
                fi
                DURANIUM_LAST_ERROR="injected partial write"
                return 1
            fi
            cp "$_src" "$_dev" || return 1
            sync 2>/dev/null || true
            ;;
        block)
            _part_size=$(backend_part_size "$_dev") || {
                DURANIUM_LAST_ERROR="cannot determine partition size for $_dev"
                return 1
            }
            if [ "$_size" -gt "$_part_size" ]; then
                DURANIUM_LAST_ERROR="image ($_size bytes) does not fit in $_dev ($_part_size bytes)"
                return 1
            fi
            if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ -n "${DURANIUM_TEST_PARTIAL_WRITE_BYTES:-}" ]; then
                dur_is_uint "$DURANIUM_TEST_PARTIAL_WRITE_BYTES" || return 1
                head -c "$DURANIUM_TEST_PARTIAL_WRITE_BYTES" "$_src" | dd of="$_dev" bs=4M conv=fsync 2>/dev/null || true
                sync 2>/dev/null || true
                if [ "${DURANIUM_TEST_POWER_LOSS:-0}" = "1" ]; then
                    exit 137
                fi
                DURANIUM_LAST_ERROR="injected partial write"
                return 1
            fi
            if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ "${DURANIUM_TEST_FAIL_AT:-}" = "write" ]; then
                DURANIUM_LAST_ERROR="injected write failure"
                return 1
            fi
            dd if="$_src" of="$_dev" bs=4M conv=fsync 2>/dev/null || {
                DURANIUM_LAST_ERROR="dd failed writing $_src to $_dev"
                return 1
            }
            sync 2>/dev/null || true
            ;;
    esac
    return 0
}

backend_readback_hash() {
    local _dev _size _slot
    _slot=$1
    _size=$2
    _dev=$(backend_slot_dev "$_slot") || return 1
    dur_is_uint "$_size" || return 1
    if [ ! -e "$_dev" ]; then
        DURANIUM_LAST_ERROR="slot device missing: $_dev"
        return 1
    fi
    dur_sha256_prefix "$_dev" "$_size"
}

backend_fsck_slot() {
    local _dev _slot
    _slot=$1
    [ "$DURANIUM_FSCK" = "1" ] || return 0
    _dev=$(backend_slot_dev "$_slot") || return 1
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        return 0
    fi
    if command -v fsck.ext4 >/dev/null 2>&1; then
        fsck.ext4 -fn "$_dev" >/dev/null 2>&1
        return $?
    fi
    return 0
}

backend_boot_path() {
    printf '%s/%s\n' "$DURANIUM_BOOT_MNT" "$1"
}

backend_boot_write() {
    local _dest _dir _rel _src
    _rel=$1
    _src=$2
    _dest=$(backend_boot_path "$_rel") || return 1
    _dir=$(dirname "$_dest")
    dur_mkdir "$_dir" || return 1
    dur_copy_atomic "$_src" "$_dest" || return 1
    return 0
}

backend_boot_write_text() {
    local _dest _dir _rel _text
    _rel=$1
    _text=$2
    _dest=$(backend_boot_path "$_rel") || return 1
    _dir=$(dirname "$_dest")
    dur_mkdir "$_dir" || return 1
    printf '%s\n' "$_text" | dur_atomic_write "$_dest"
}

backend_boot_hash() {
    local _path _rel
    _rel=$1
    _path=$(backend_boot_path "$_rel") || return 1
    [ -r "$_path" ] || return 1
    dur_sha256_file "$_path"
}

backend_boot_size() {
    local _path _rel
    _rel=$1
    _path=$(backend_boot_path "$_rel") || return 1
    [ -r "$_path" ] || return 1
    wc -c < "$_path" | tr -d ' '
}

backend_boot_remove() {
    local _path _rel
    _rel=$1
    _path=$(backend_boot_path "$_rel") || return 1
    rm -f "$_path"
}

backend_mount_slot_ro() {
    local _dev _mnt _slot
    _slot=$1
    _mnt=$2
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        return 0
    fi
    _dev=$(backend_slot_dev "$_slot") || return 1
    dur_mkdir "$_mnt" || return 1
    mount -t ext4 -o ro "$_dev" "$_mnt" 2>/dev/null || {
        DURANIUM_LAST_ERROR="cannot mount $_dev read-only at $_mnt"
        return 1
    }
    return 0
}

backend_mount_state() {
    local _dev _mnt _mode
    _mnt=$1
    _mode=${2:-rw}
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        return 0
    fi
    _dev=$DURANIUM_STATE_DEV
    dur_mkdir "$_mnt" || return 1
    if [ "$_mode" = "ro" ]; then
        mount -t ext4 -o ro "$_dev" "$_mnt" 2>/dev/null || {
            DURANIUM_LAST_ERROR="cannot mount state device read-only"
            return 1
        }
    else
        mount -t ext4 -o rw "$_dev" "$_mnt" 2>/dev/null || {
            DURANIUM_LAST_ERROR="cannot mount state device read-write"
            return 1
        }
    fi
    return 0
}

backend_umount() {
    dur_umount "$1"
}

backend_state_format() {
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        rm -rf "$DURANIUM_STATE_MNT"
        dur_mkdir "$DURANIUM_STATE_MNT" || return 1
        return 0
    fi
    if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ "${DURANIUM_TEST_FAIL_AT:-}" = "state-format" ]; then
        DURANIUM_LAST_ERROR="injected state format failure"
        return 1
    fi
    if ! command -v mke2fs >/dev/null 2>&1; then
        DURANIUM_LAST_ERROR="mke2fs is not available; cannot wipe STATE"
        return 1
    fi
    dur_umount "$DURANIUM_STATE_MNT" || return 1
    mke2fs -t ext4 -F -L duranium-state "$DURANIUM_STATE_DEV" >/dev/null 2>&1 || {
        DURANIUM_LAST_ERROR="mke2fs failed on state device"
        return 1
    }
    sync 2>/dev/null || true
    return 0
}
