#!/bin/sh
# Strict slot/global metadata.
#
# Format: canonical "key=value" lines, fixed field order, one trailing
# "checksum=<sha256>" line. The checksum covers every byte before the checksum
# line. Unknown, duplicate, reordered, or malformed fields are rejected.
#
# The authoritative copies live on BOOT, never in STATE:
#   $DURANIUM_META_DIR/global.meta      (+ .bak)
#   $DURANIUM_META_DIR/slots/A.meta     (+ .bak)
#   $DURANIUM_META_DIR/slots/B.meta     (+ .bak)

SLOT_FIELDS="duranium_meta kind slot alloy_version build_id image_sha256 image_size boot_kernel_sha256 boot_initramfs_sha256 profile architecture hardware_target state_schema status boot_attempts_remaining max_boot_attempts known_good pending_boot_id generation updated_at"
GLOBAL_FIELDS="duranium_meta kind active_slot pending_slot fallback_slot last_known_good_slot update_in_progress generation updated_at"

meta_slot_path() {
    printf '%s/slots/%s.meta\n' "$DURANIUM_META_DIR" "$1"
}

meta_global_path() {
    printf '%s/global.meta\n' "$DURANIUM_META_DIR"
}

meta_value_ok() {
    # Metadata values are single tokens. This deliberately excludes spaces,
    # '=' and newlines; it keeps parsing deterministic on FAT.
    case "${1:-}" in
        *[!A-Za-z0-9._:/+,@-]*) return 1 ;;
    esac
    return 0
}

meta_val() {
    # meta_val <PREFIX> <field>
    eval "printf '%s' \"\${${1}_${2}-}\""
}

meta_render_slot_prefix() {
    local _p
    _p=$1
    printf 'duranium_meta=%s\n' "$(meta_val "$_p" duranium_meta)"
    printf 'kind=%s\n' "$(meta_val "$_p" kind)"
    printf 'slot=%s\n' "$(meta_val "$_p" slot)"
    printf 'alloy_version=%s\n' "$(meta_val "$_p" alloy_version)"
    printf 'build_id=%s\n' "$(meta_val "$_p" build_id)"
    printf 'image_sha256=%s\n' "$(meta_val "$_p" image_sha256)"
    printf 'image_size=%s\n' "$(meta_val "$_p" image_size)"
    printf 'boot_kernel_sha256=%s\n' "$(meta_val "$_p" boot_kernel_sha256)"
    printf 'boot_initramfs_sha256=%s\n' "$(meta_val "$_p" boot_initramfs_sha256)"
    printf 'profile=%s\n' "$(meta_val "$_p" profile)"
    printf 'architecture=%s\n' "$(meta_val "$_p" architecture)"
    printf 'hardware_target=%s\n' "$(meta_val "$_p" hardware_target)"
    printf 'state_schema=%s\n' "$(meta_val "$_p" state_schema)"
    printf 'status=%s\n' "$(meta_val "$_p" status)"
    printf 'boot_attempts_remaining=%s\n' "$(meta_val "$_p" boot_attempts_remaining)"
    printf 'max_boot_attempts=%s\n' "$(meta_val "$_p" max_boot_attempts)"
    printf 'known_good=%s\n' "$(meta_val "$_p" known_good)"
    printf 'pending_boot_id=%s\n' "$(meta_val "$_p" pending_boot_id)"
    printf 'generation=%s\n' "$(meta_val "$_p" generation)"
    printf 'updated_at=%s\n' "$(meta_val "$_p" updated_at)"
}

meta_render_global_prefix() {
    local _p
    _p=$1
    printf 'duranium_meta=%s\n' "$(meta_val "$_p" duranium_meta)"
    printf 'kind=%s\n' "$(meta_val "$_p" kind)"
    printf 'active_slot=%s\n' "$(meta_val "$_p" active_slot)"
    printf 'pending_slot=%s\n' "$(meta_val "$_p" pending_slot)"
    printf 'fallback_slot=%s\n' "$(meta_val "$_p" fallback_slot)"
    printf 'last_known_good_slot=%s\n' "$(meta_val "$_p" last_known_good_slot)"
    printf 'update_in_progress=%s\n' "$(meta_val "$_p" update_in_progress)"
    printf 'generation=%s\n' "$(meta_val "$_p" generation)"
    printf 'updated_at=%s\n' "$(meta_val "$_p" updated_at)"
}

meta_parse_file() {
    local _cr _expect _fields _file _k _key _kind _line _sum _value
    _file=$1
    _kind=$2
    MP_BODY=""
    MP_BODY_NO_NL=""
    MP_CHECKSUM=""
    MP_CHECKSUM_SEEN=""
    MP_SEEN=""
    MP_SOURCE=""
    case "$_kind" in
        slot) _fields=$SLOT_FIELDS ;;
        global) _fields=$GLOBAL_FIELDS ;;
        *) return 1 ;;
    esac
    for _k in $_fields; do
        eval "MP_$_k=''"
    done
    [ -r "$_file" ] || return 1
    _cr=$(printf '\r')
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            *"$_cr"*) return 1 ;;
        esac
        case "$_line" in
            *=*) ;;
            *) return 1 ;;
        esac
        _key=${_line%%=*}
        _value=${_line#*=}
        case "$_key" in
            ''|[0-9]*|*[!a-z0-9_]*) return 1 ;;
        esac
        case " $MP_SEEN " in
            *" $_key "*) return 1 ;;
        esac
        MP_SEEN="$MP_SEEN $_key"
        if [ "$_key" = "checksum" ]; then
            MP_CHECKSUM=$_value
            MP_CHECKSUM_SEEN=1
            continue
        fi
        # The checksum line must be the final line.
        [ -z "$MP_CHECKSUM_SEEN" ] || return 1
        case " $_fields " in
            *" $_key "*) ;;
            *) return 1 ;;
        esac
        meta_value_ok "$_value" || return 1
        eval "MP_$_key=\$_value"
        MP_BODY="${MP_BODY}${_line}
"
    done < "$_file"
    [ -n "$MP_CHECKSUM" ] || return 1
    [ -n "$MP_BODY" ] || return 1
    _sum=$(printf '%s' "$MP_BODY" | dur_sha256_stdin) || return 1
    [ "$_sum" = "$MP_CHECKSUM" ] || return 1
    MP_BODY_NO_NL=${MP_BODY%?}
    case "$_kind" in
        slot)
            _expect=$(meta_render_slot_prefix MP) || return 1
            ;;
        global)
            _expect=$(meta_render_global_prefix MP) || return 1
            ;;
    esac
    [ "$_expect" = "$MP_BODY_NO_NL" ] || return 1
    [ "$(meta_val MP duranium_meta)" = "1" ] || return 1
    [ "$(meta_val MP kind)" = "$_kind" ] || return 1
    return 0
}

meta_copy_parsed() {
    local _k _kind
    _kind=$1
    case "$_kind" in
        slot)
            for _k in $SLOT_FIELDS; do
                eval "MS_$_k=\$(meta_val MP \"$_k\")"
            done
            ;;
        global)
            for _k in $GLOBAL_FIELDS; do
                eval "MG_$_k=\$(meta_val MP \"$_k\")"
            done
            ;;
        *) return 1 ;;
    esac
    return 0
}

meta_validate_slot() {
    local _attempts _known _max _status
    _status=$MS_status
    _known=$MS_known_good
    _attempts=$MS_boot_attempts_remaining
    _max=$MS_max_boot_attempts
    dur_is_slot "$MS_slot" || return 1
    [ -n "$MS_alloy_version" ] || return 1
    [ -n "$MS_build_id" ] || return 1
    case "$MS_profile" in dev|lab|prod) ;; *) return 1 ;; esac
    [ -n "$MS_architecture" ] || return 1
    [ -n "$MS_hardware_target" ] || return 1
    dur_is_uint "$MS_state_schema" || return 1
    [ "$MS_state_schema" -ge 1 ] || return 1
    case "$_status" in UNKNOWN|PENDING|GOOD|BAD) ;; *) return 1 ;; esac
    dur_is_uint "$_attempts" || return 1
    dur_is_uint "$_max" || return 1
    [ "$_max" -ge 1 ] && [ "$_max" -le 20 ] || return 1
    [ "$_attempts" -le "$_max" ] || return 1
    case "$_known" in 0|1) ;; *) return 1 ;; esac
    dur_is_uint "$MS_generation" || return 1
    [ "$MS_generation" -ge 1 ] || return 1
    [ -n "$MS_updated_at" ] || return 1
    if [ -n "${MS_image_size:-}" ]; then
        dur_is_uint "${MS_image_size:-}" || return 1
        [ "${MS_image_size:-}" -gt 0 ] || return 1
    fi
    case "$_status" in
        GOOD)
            [ "$_known" = "1" ] || return 1
            dur_is_hex64 "$MS_image_sha256" || return 1
            dur_is_hex64 "$MS_boot_kernel_sha256" || return 1
            dur_is_hex64 "$MS_boot_initramfs_sha256" || return 1
            ;;
        PENDING)
            [ "$_known" = "0" ] || return 1
            dur_is_hex64 "$MS_image_sha256" || return 1
            dur_is_hex64 "$MS_boot_kernel_sha256" || return 1
            dur_is_hex64 "$MS_boot_initramfs_sha256" || return 1
            ;;
        UNKNOWN|BAD)
            [ "$_known" = "0" ] || return 1
            [ "$_attempts" -eq 0 ] || return 1
            if [ -n "$MS_image_sha256" ]; then
                dur_is_hex64 "$MS_image_sha256" || return 1
            fi
            if [ -n "$MS_boot_kernel_sha256" ]; then
                dur_is_hex64 "$MS_boot_kernel_sha256" || return 1
            fi
            if [ -n "$MS_boot_initramfs_sha256" ]; then
                dur_is_hex64 "$MS_boot_initramfs_sha256" || return 1
            fi
            ;;
    esac
    if [ -n "$MS_pending_boot_id" ]; then
        case "$MS_pending_boot_id" in
            *[!A-Za-z0-9-]*) return 1 ;;
        esac
    fi
    return 0
}

meta_validate_global() {
    local _a _f _l _p _u _v
    _a=$MG_active_slot
    _p=$MG_pending_slot
    _f=$MG_fallback_slot
    _l=$MG_last_known_good_slot
    _u=$MG_update_in_progress
    for _v in "$_a" "$_p" "$_f" "$_l" "$_u"; do
        case "$_v" in
            ''|A|B) ;;
            *) return 1 ;;
        esac
    done
    if [ -n "$_a" ] && [ -n "$_p" ] && [ "$_a" = "$_p" ]; then
        return 1
    fi
    dur_is_uint "$MG_generation" || return 1
    [ "$MG_generation" -ge 1 ] || return 1
    [ -n "$MG_updated_at" ] || return 1
    return 0
}

meta_load_slot() {
    local _path _slot
    _slot=$1
    dur_is_slot "$_slot" || return 1
    _path=$(meta_slot_path "$_slot")
    MS_SOURCE=""
    if meta_parse_file "$_path" slot && meta_copy_parsed slot && meta_validate_slot && [ "$MS_slot" = "$_slot" ]; then
        MS_SOURCE=primary
        return 0
    fi
    if meta_parse_file "$_path.bak" slot && meta_copy_parsed slot && meta_validate_slot && [ "$MS_slot" = "$_slot" ]; then
        MS_SOURCE=backup
        dur_warn "slot $_slot metadata primary is invalid; using backup"
        return 0
    fi
    DURANIUM_LAST_ERROR="slot $_slot metadata is invalid or missing"
    return 1
}

meta_load_global() {
    local _path
    _path=$(meta_global_path)
    MG_SOURCE=""
    if meta_parse_file "$_path" global && meta_copy_parsed global && meta_validate_global; then
        MG_SOURCE=primary
        return 0
    fi
    if meta_parse_file "$_path.bak" global && meta_copy_parsed global && meta_validate_global; then
        MG_SOURCE=backup
        dur_warn "global metadata primary is invalid; using backup"
        return 0
    fi
    DURANIUM_LAST_ERROR="global metadata is invalid or missing"
    return 1
}

meta_write_file() {
    local _dest _dir _kind _text
    _dest=$1
    _text=$2
    _dir=$(dirname "$_dest")
    dur_mkdir "$_dir" || return 1
    if [ -e "$_dest" ]; then
        # Preserve the last valid primary as the backup before replacing it.
        # Never overwrite a good backup with a corrupt primary.
        case "$(basename "$_dest")" in
            global.meta) _kind=global ;;
            *) _kind=slot ;;
        esac
        if meta_parse_file "$_dest" "$_kind" >/dev/null 2>&1; then
            # The backup copy must itself be atomic: a truncated .bak right
            # before the primary is replaced is exactly the dual-corruption
            # window the redundancy exists to prevent.
            dur_copy_atomic "$_dest" "$_dest.bak" || {
                rm -f "$_dest.bak.tmp.$$" 2>/dev/null || true
                dur_err "cannot create metadata backup $_dest.bak"
                return 1
            }
        fi
    fi
    printf '%s\n' "$_text" | dur_atomic_write "$_dest" || return 1
    return 0
}

meta_write_slot() {
    local _body _sum _text
    meta_validate_slot || {
        DURANIUM_LAST_ERROR="refusing to write invalid slot metadata: $DURANIUM_LAST_ERROR"
        return 1
    }
    _body=$(meta_render_slot_prefix MS) || return 1
    _sum=$(printf '%s\n' "$_body" | dur_sha256_stdin) || return 1
    _text=$(printf '%s\nchecksum=%s' "$_body" "$_sum")
    meta_write_file "$(meta_slot_path "$MS_slot")" "$_text"
}

meta_write_global() {
    local _body _sum _text
    meta_validate_global || {
        DURANIUM_LAST_ERROR="refusing to write invalid global metadata"
        return 1
    }
    _body=$(meta_render_global_prefix MG) || return 1
    _sum=$(printf '%s\n' "$_body" | dur_sha256_stdin) || return 1
    _text=$(printf '%s\nchecksum=%s' "$_body" "$_sum")
    meta_write_file "$(meta_global_path)" "$_text"
}

meta_apply_updates() {
    local _fields _k _kind _kv _p _set _v
    # meta_apply_updates <PREFIX> <kind> key=value...
    _p=$1
    _kind=$2
    shift 2
    case "$_kind" in
        slot) _fields=$SLOT_FIELDS ;;
        global) _fields=$GLOBAL_FIELDS ;;
        *) return 1 ;;
    esac
    for _kv in "$@"; do
        case "$_kv" in
            *=*) ;;
            *) dur_err "invalid metadata update '$_kv'"; return 1 ;;
        esac
        _k=${_kv%%=*}
        _v=${_kv#*=}
        # Identity fields define which file a record lives in; rewriting them
        # would let a checksum-valid record land under the wrong name.
        case "$_k" in
            duranium_meta|kind) dur_err "refusing to update identity field '$_k'"; return 1 ;;
            slot) [ "$_kind" = "slot" ] && { dur_err "refusing to update identity field 'slot'"; return 1; } ;;
        esac
        case " $_fields " in
            *" $_k "*) ;;
            *) dur_err "unknown metadata field '$_k'"; return 1 ;;
        esac
        meta_value_ok "$_v" || { dur_err "invalid value for '$_k'"; return 1; }
        eval "${_p}_$_k=\$_v"
        eval "${_p}_${_k}_set=1"
    done
    return 0
}

# Read-modify-write sequences on the metadata files are not otherwise
# serialized: a concurrent boot-reconcile running between an updater's load
# and write could clobber the transaction. Every mutating entry point takes
# this lock. Re-entrant within one process (the updater already holds the
# update lock and calls meta_update_* in its phases).
META_LOCK_HELD=0
META_LOCK=""

meta_lock() {
    local _lock _old _steal _tries _valid
    [ "$META_LOCK_HELD" = "1" ] && return 0
    _lock="$DURANIUM_RUN/meta.lock"
    dur_mkdir "$DURANIUM_RUN" || return 1
    _tries=0
    while :; do
        if [ -d "$_lock" ]; then
            _old=$(cat "$_lock/pid" 2>/dev/null || true)
            if [ -z "$_old" ]; then
                # The holder may be between mkdir and the pid write.
                sleep 1
                _old=$(cat "$_lock/pid" 2>/dev/null || true)
            fi
            _valid=0
            if dur_is_uint "$_old" && [ -d "/proc/$_old" ]; then
                if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] || \
                   grep -q duranium "/proc/$_old/cmdline" 2>/dev/null; then
                    _valid=1
                fi
            fi
            if [ "$_valid" = "1" ]; then
                DURANIUM_LAST_ERROR="metadata is locked by another duranium process (pid $_old)"
                return 1
            fi
            # Stale. Rename-steal so two stealers cannot both win: only the
            # one whose mv succeeds owns the removal.
            _steal="$_lock.steal.$$"
            if mv "$_lock" "$_steal" 2>/dev/null; then
                rm -rf "$_steal" 2>/dev/null || true
            else
                _tries=$((_tries + 1))
                [ "$_tries" -le 5 ] || {
                    DURANIUM_LAST_ERROR="cannot steal stale metadata lock"
                    return 1
                }
                continue
            fi
        fi
        # mkdir without -p is atomic: a contender cannot create the same lock.
        if mkdir "$_lock" 2>/dev/null; then
            printf '%s\n' "$$" > "$_lock/pid"
            META_LOCK="$_lock"
            META_LOCK_HELD=1
            return 0
        fi
        _tries=$((_tries + 1))
        [ "$_tries" -le 5 ] || {
            DURANIUM_LAST_ERROR="cannot create metadata lock"
            return 1
        }
    done
}

meta_unlock() {
    if [ "${META_LOCK_HELD:-0}" = "1" ] && [ -n "${META_LOCK:-}" ] && [ -d "$META_LOCK" ]; then
        rm -rf "$META_LOCK" 2>/dev/null || true
    fi
    META_LOCK=""
    META_LOCK_HELD=0
}

meta_update_slot() {
    local _rc _slot
    _slot=$1
    shift
    meta_lock || return 1
    meta_load_slot "$_slot" || { _rc=1; }
    if [ "${_rc:-0}" -eq 0 ]; then
        if meta_apply_updates MS slot "$@" && \
           { MS_generation=$((MS_generation + 1)); MS_updated_at=$(dur_timestamp); meta_write_slot; }; then
            _rc=0
        else
            _rc=1
        fi
    fi
    meta_unlock
    return "$_rc"
}

meta_update_global() {
    local _rc
    meta_lock || return 1
    if meta_load_global && meta_apply_updates MG global "$@" && \
       { MG_generation=$((MG_generation + 1)); MG_updated_at=$(dur_timestamp); meta_write_global; }; then
        _rc=0
    else
        _rc=1
    fi
    meta_unlock
    return "$_rc"
}

meta_init_slot() {
    local _slot
    _slot=$1
    shift
    dur_is_slot "$_slot" || return 1
    MS_duranium_meta=1
    MS_kind=slot
    MS_slot=$_slot
    MS_alloy_version=unknown
    MS_build_id=unknown
    MS_image_sha256=
    MS_image_size=
    MS_boot_kernel_sha256=
    MS_boot_initramfs_sha256=
    MS_profile=$DURANIUM_PROFILE
    MS_architecture=$DURANIUM_ARCH
    MS_hardware_target=$DURANIUM_HARDWARE_TARGET
    MS_state_schema=$DURANIUM_STATE_SCHEMA
    MS_status=UNKNOWN
    MS_boot_attempts_remaining=0
    MS_max_boot_attempts=$DURANIUM_MAX_BOOT_ATTEMPTS
    MS_known_good=0
    MS_pending_boot_id=
    MS_generation=1
    MS_updated_at=$(dur_timestamp)
    meta_apply_updates MS slot "$@" || return 1
    meta_validate_slot || return 1
    meta_write_slot
}

meta_init_global() {
    MG_duranium_meta=1
    MG_kind=global
    MG_active_slot=A
    MG_pending_slot=
    MG_fallback_slot=A
    MG_last_known_good_slot=A
    MG_update_in_progress=
    MG_generation=1
    MG_updated_at=$(dur_timestamp)
    meta_apply_updates MG global "$@" || return 1
    meta_validate_global || return 1
    meta_write_global
}

meta_slot_primary_valid() {
    meta_parse_file "$(meta_slot_path "$1")" slot >/dev/null 2>&1
}

meta_global_primary_valid() {
    meta_parse_file "$(meta_global_path)" global >/dev/null 2>&1
}

meta_repair_primary() {
    local _kind _path _slot
    # Copy a valid backup back to primary. Returns 0 if repaired/valid.
    _kind=$1
    _slot=${2:-}
    case "$_kind" in
        slot)
            _path=$(meta_slot_path "$_slot")
            meta_parse_file "$_path" slot >/dev/null 2>&1 && return 0
            meta_parse_file "$_path.bak" slot >/dev/null 2>&1 || return 1
            dur_copy_atomic "$_path.bak" "$_path" || return 1
            rm -f "$_path.tmp.$$" 2>/dev/null || true
            sync 2>/dev/null || true
            ;;
        global)
            _path=$(meta_global_path)
            meta_parse_file "$_path" global >/dev/null 2>&1 && return 0
            meta_parse_file "$_path.bak" global >/dev/null 2>&1 || return 1
            dur_copy_atomic "$_path.bak" "$_path" || return 1
            rm -f "$_path.tmp.$$" 2>/dev/null || true
            sync 2>/dev/null || true
            ;;
        *) return 1 ;;
    esac
    return 0
}

meta_slot_summary() {
    local _slot
    _slot=$1
    if meta_load_slot "$_slot"; then
        printf 'slot %s: status=%s known_good=%s boot_attempts_remaining=%s max_boot_attempts=%s version=%s build=%s image_size=%s schema=%s source=%s\n' \
            "$_slot" "$MS_status" "$MS_known_good" "$MS_boot_attempts_remaining" "$MS_max_boot_attempts" \
            "$MS_alloy_version" "$MS_build_id" "${MS_image_size:-}" "$MS_state_schema" "$MS_SOURCE"
        return 0
    fi
    printf 'slot %s: INVALID/MISSING (%s)\n' "$_slot" "${DURANIUM_LAST_ERROR:-unknown error}"
    return 1
}
