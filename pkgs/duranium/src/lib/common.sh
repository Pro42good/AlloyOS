#!/bin/sh
# Duranium common helpers.
#
# This file must stay POSIX-shell and BusyBox compatible: it is sourced by the
# normal userland, by the initramfs, and by the recovery environment.

DURANIUM_VERSION="0.1.0"
DURANIUM_FORMAT_VERSION=1
DURANIUM_LAST_ERROR=""

dur_err() {
    printf 'duranium: error: %s\n' "$*" >&2
}

dur_warn() {
    printf 'duranium: warning: %s\n' "$*" >&2
}

dur_log() {
    printf 'duranium: %s\n' "$*"
}

dur_die() {
    dur_err "$*"
    exit 1
}

dur_is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

dur_is_hex64() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0-9a-fA-F]*) return 1 ;;
    esac
    return 0
}

dur_is_safe_id() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

dur_is_slot() {
    case "${1:-}" in
        A|B) return 0 ;;
    esac
    return 1
}

dur_other_slot() {
    case "${1:-}" in
        A) printf 'B\n' ;;
        B) printf 'A\n' ;;
        *) return 1 ;;
    esac
}

dur_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

dur_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

dur_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        return 1
    fi
}

# Hash exactly $2 bytes from the beginning of file/device $1.
#
# Read in bounded chunks. On some platforms (observed with QEMU/hvf on macOS)
# very large sequential reads from a block device can return stale bytes even
# while small reads of the same blocks return the correct content, which would
# silently corrupt install read-back and root-image verification. 1 MiB chunked
# reads are correct everywhere and cost the same overall. dd's skip counts
# blocks of bs, so the loop passes the chunk index; the final short chunk is
# trimmed to the exact remaining length.
dur_sha256_prefix() {
    local _chunk _file _i _left _size
    _file=$1
    _size=$2
    dur_is_uint "$_size" || return 1
    _chunk=1048576
    {
        _i=0
        while [ "$((_i * _chunk))" -lt "$_size" ]; do
            _left=$((_size - _i * _chunk))
            if [ "$_left" -ge "$_chunk" ]; then
                dd if="$_file" bs="$_chunk" count=1 skip="$_i" 2>/dev/null || exit 1
            else
                dd if="$_file" bs="$_chunk" count=1 skip="$_i" 2>/dev/null | head -c "$_left" || exit 1
            fi
            _i=$((_i + 1))
        done
    } | dur_sha256_stdin
}

dur_mkdir() {
    [ -d "$1" ] || mkdir -p "$1"
}

# Write stdin to $1 atomically where the filesystem supports rename.
# The caller is responsible for the directory existing.
dur_atomic_write() {
    local _dest _tmp
    _dest=$1
    _tmp="${_dest}.tmp.$$"
    if ! cat > "$_tmp"; then
        rm -f "$_tmp"
        return 1
    fi
    sync 2>/dev/null || true
    if ! mv -f "$_tmp" "$_dest"; then
        rm -f "$_tmp"
        return 1
    fi
    sync 2>/dev/null || true
    return 0
}

dur_atomic_write_text() {
    local _dest _text
    _dest=$1
    _text=$2
    printf '%s\n' "$_text" | dur_atomic_write "$_dest"
}

dur_copy_atomic() {
    local _dst _src _tmp
    _src=$1
    _dst=$2
    _tmp="${_dst}.tmp.$$"
    if ! cp "$_src" "$_tmp"; then
        rm -f "$_tmp"
        return 1
    fi
    sync 2>/dev/null || true
    if ! mv -f "$_tmp" "$_dst"; then
        rm -f "$_tmp"
        return 1
    fi
    sync 2>/dev/null || true
    return 0
}

dur_read_file() {
    [ -r "$1" ] || return 1
    cat "$1"
}

dur_is_mounted() {
    local _path
    _path=$1
    [ -r /proc/mounts ] || return 1
    awk -v p="$_path" '$2 == p { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts
}

dur_mount_opts() {
    local _path
    _path=$1
    [ -r /proc/mounts ] || return 1
    awk -v p="$_path" '$2 == p { print $4; exit }' /proc/mounts
}

dur_filesystem_type() {
    local _path
    _path=$1
    [ -r /proc/mounts ] || return 1
    awk -v p="$_path" '$2 == p { print $3; exit }' /proc/mounts
}

dur_umount() {
    local _path
    _path=$1
    if dur_is_mounted "$_path"; then
        umount "$_path" 2>/dev/null || return 1
    fi
    return 0
}

dur_boot_id() {
    # Test hook: lets the unit suite simulate distinct boots.
    if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ -n "${DURANIUM_TEST_BOOT_ID:-}" ]; then
        printf '%s\n' "$DURANIUM_TEST_BOOT_ID"
        return 0
    fi
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        tr -d '\n' < /proc/sys/kernel/random/boot_id
    else
        printf 'unknown\n'
    fi
}

dur_cmdline() {
    if [ -r /proc/cmdline ]; then
        tr -d '\n' < /proc/cmdline
    fi
}

# Print the value of key=value from the kernel command line.
dur_cmdline_value() {
    local _line _want _word
    _want=$1
    _line=$(dur_cmdline)
    for _word in $_line; do
        case "$_word" in
            "$_want"=*) printf '%s\n' "${_word#*=}"; return 0 ;;
        esac
    done
    return 1
}

dur_require_root() {
    if [ "$(id -u)" -ne 0 ] && [ "${DURANIUM_TEST_MODE:-0}" != "1" ]; then
        dur_err "this command must run as root"
        return 1
    fi
    return 0
}

dur_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Reject values that cannot be represented safely in our line-oriented files.
dur_is_token() {
    case "${1:-}" in
        *'
'*) return 1 ;;
        *' '*) return 1 ;;
        *'	'*) return 1 ;;
        *'='*) return 1 ;;
        *"$(printf '\r')"*) return 1 ;;
    esac
    return 0
}

dur_cleanup_run_tmp() {
    if [ -n "${DURANIUM_TMP:-}" ] && [ -d "$DURANIUM_TMP" ]; then
        rm -rf "$DURANIUM_TMP" 2>/dev/null || true
    fi
}
