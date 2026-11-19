#!/bin/sh
# Recovery CLI. Runs only from the independent RECOVERY environment, never
# from a normal system slot.
#
# Recovery deliberately has no GUI and no automatic repair. It can inspect,
# select, mark, reinstall, repair metadata, mount STATE, and wipe STATE only
# when explicitly requested.

recovery_require_context() {
    if [ "${DURANIUM_RECOVERY:-0}" = "1" ] || [ -e "$DURANIUM_RUN/recovery" ]; then
        return 0
    fi
    if [ "$DURANIUM_TEST_MODE" = "1" ] && [ "$DURANIUM_BACKEND" = "dir" ]; then
        return 0
    fi
    dur_err "recovery commands are only available in the recovery environment"
    return 1
}

recovery_status() {
    local _schema
    recovery_require_context || return 1
    slot_status || true
    printf '\nBoot entries:\n'
    bootloader_list || true
    printf '\nSTATE: '
    if dur_is_mounted "$DURANIUM_STATE_MNT"; then
        _schema=$(state_schema_get 2>/dev/null || true)
        [ -n "$_schema" ] || _schema=unknown
        printf 'mounted at %s (schema %s)\n' "$DURANIUM_STATE_MNT" "$_schema"
    else
        printf 'not mounted\n'
    fi
    return 0
}

recovery_inspect() {
    local _dev _f _size _slot
    recovery_require_context || return 1
    bootloader_init || return 1
    for _slot in A B; do
        printf '=== slot %s ===\n' "$_slot"
        if meta_load_slot "$_slot"; then
            printf 'status=%s known_good=%s build=%s version=%s schema=%s attempts=%s/%s\n' \
                "$MS_status" "$MS_known_good" "$MS_build_id" "$MS_alloy_version" \
                "$MS_state_schema" "$MS_boot_attempts_remaining" "$MS_max_boot_attempts"
            printf 'image_sha256=%s\n' "$MS_image_sha256"
        else
            printf 'metadata: INVALID/MISSING (%s)\n' "${DURANIUM_LAST_ERROR:-unknown}"
        fi
        _dev=$(backend_slot_dev "$_slot" 2>/dev/null || true)
        if [ -n "$_dev" ] && [ -e "$_dev" ]; then
            _size=$(backend_part_size "$_dev" 2>/dev/null || true)
            printf 'device=%s size=%s\n' "$_dev" "${_size:-unknown}"
            if [ -n "$_size" ] && [ "$_size" -gt 0 ]; then
                printf 'device_sha256=%s\n' "$(dur_sha256_prefix "$_dev" "$_size" 2>/dev/null || printf 'unreadable')"
            fi
        fi
        for _f in "$DURANIUM_BOOT_MNT/duranium/boot/$_slot/vmlinuz" "$DURANIUM_BOOT_MNT/duranium/boot/$_slot/initramfs"; do
            if [ -r "$_f" ]; then
                printf 'boot_file=%s sha256=%s\n' "$_f" "$(dur_sha256_file "$_f")"
            else
                printf 'boot_file=%s MISSING\n' "$_f"
            fi
        done
        printf 'entry_state=%s\n' "$(bootloader_entry_state "$_slot")"
    done
    return 0
}

recovery_set_good() {
    local _fallback _old _slot
    _slot=$1
    recovery_require_context || return 1
    dur_is_slot "$_slot" || { dur_err "recovery mark-good: invalid slot"; return 1; }
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    _old=$MG_active_slot
    _fallback=$_old
    if [ -z "$_fallback" ] || [ "$_fallback" = "$_slot" ]; then
        _fallback=$MG_fallback_slot
    fi
    if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
        _fallback=""
    fi
    meta_update_slot "$_slot" status=GOOD known_good=1 boot_attempts_remaining=0 pending_boot_id= || return 1
    meta_update_global active_slot="$_slot" pending_slot="" fallback_slot="$_fallback" last_known_good_slot="$_slot" || return 1
    bootloader_sync || return 1
    dur_log "recovery: slot $_slot marked GOOD"
    return 0
}

recovery_set_bad() {
    local _slot
    _slot=$1
    recovery_require_context || return 1
    slot_mark_bad "$_slot"
}

recovery_select() {
    local _force _slot
    _slot=$1
    _force=${2:-0}
    recovery_require_context || return 1
    slot_select "$_slot" "$_force"
}

recovery_reinstall() {
    local _allow_profile _dir _reboot _slot
    _slot=$1
    _dir=$2
    _allow_profile=${3:-0}
    _reboot=${4:-0}
    recovery_require_context || return 1
    dur_is_slot "$_slot" || { dur_err "recovery reinstall: invalid slot"; return 1; }
    update_install "$_dir" "$_allow_profile" "$_reboot" "$_slot" 1
}

recovery_mount_state() {
    recovery_require_context || return 1
    if dur_is_mounted "$DURANIUM_STATE_MNT"; then
        dur_log "STATE already mounted at $DURANIUM_STATE_MNT"
        return 0
    fi
    backend_mount_state "$DURANIUM_STATE_MNT" rw || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    dur_log "STATE mounted at $DURANIUM_STATE_MNT"
    return 0
}

recovery_umount_state() {
    recovery_require_context || return 1
    dur_umount "$DURANIUM_STATE_MNT" || { dur_err "cannot unmount STATE"; return 1; }
    return 0
}

recovery_repair_boot() {
    local _active _fallback _last _slot
    recovery_require_context || return 1
    bootloader_init || return 1
    for _slot in A B; do
        if ! meta_slot_primary_valid "$_slot"; then
            if meta_repair_primary slot "$_slot"; then
                dur_log "repaired slot $_slot metadata from backup"
            else
                dur_warn "slot $_slot metadata is unrecoverable; creating UNKNOWN metadata"
                meta_init_slot "$_slot" || true
            fi
        fi
    done
    if ! meta_global_primary_valid; then
        if meta_repair_primary global; then
            dur_log "repaired global metadata from backup"
        else
            dur_warn "global metadata is unrecoverable; reconstructing from slot state"
            _active=""
            _fallback=""
            _last=""
            if meta_load_slot A && [ "$MS_status" = "GOOD" ]; then
                _active=A; _fallback=A; _last=A
            fi
            if meta_load_slot B && [ "$MS_status" = "GOOD" ]; then
                if [ -z "$_active" ]; then _active=B; _last=B; else _fallback=B; fi
            fi
            meta_init_global active_slot="$_active" pending_slot="" fallback_slot="$_fallback" last_known_good_slot="$_last" update_in_progress="" || return 1
        fi
    fi
    meta_load_global || return 1

    # Drop a pending pointer that is not actually pending, and repair active /
    # fallback pointers that refer to non-GOOD slots.
    if [ -n "$MG_pending_slot" ]; then
        if ! meta_load_slot "$MG_pending_slot" || [ "$MS_status" != "PENDING" ]; then
            meta_update_global pending_slot="" || return 1
            meta_load_global || return 1
        fi
    fi
    _active=$MG_active_slot
    if [ -n "$_active" ] && ! slot_is_good "$_active"; then
        _active=""
    fi
    if [ -z "$_active" ]; then
        if dur_is_slot "$MG_fallback_slot" && slot_is_good "$MG_fallback_slot"; then
            _active=$MG_fallback_slot
        elif slot_is_good A; then
            _active=A
        elif slot_is_good B; then
            _active=B
        fi
    fi
    _fallback=$MG_fallback_slot
    if [ -n "$_fallback" ] && { [ "$_fallback" = "$_active" ] || ! slot_is_good "$_fallback"; }; then
        _fallback=""
    fi
    if [ -z "$_fallback" ] && [ -n "$_active" ]; then
        _fallback=$_active
    fi
    _last=$MG_last_known_good_slot
    if [ -n "$_last" ] && ! slot_is_good "$_last"; then
        _last=$_fallback
    fi
    meta_update_global active_slot="$_active" fallback_slot="$_fallback" last_known_good_slot="$_last" || return 1
    bootloader_sync || return 1
    dur_log "recovery: boot metadata repaired"
    return 0
}

recovery_factory_reset() {
    local _mode _slot _yes
    _mode=$1
    _yes=$2
    recovery_require_context || return 1
    [ "$_yes" = "1" ] || {
        dur_err "factory reset requires explicit --yes"
        return 1
    }
    state_load_config || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    case "$_mode" in
        os|state|full) ;;
        *) dur_err "factory reset mode must be os, state, or full"; return 1 ;;
    esac

    if [ "$_mode" = "os" ] || [ "$_mode" = "full" ]; then
        meta_load_global || {
            # Create a minimal global record if metadata was destroyed.
            meta_init_global active_slot="" pending_slot="" fallback_slot="" last_known_good_slot="" update_in_progress="" || return 1
        }
        for _slot in A B; do
            if meta_load_slot "$_slot"; then
                meta_update_slot "$_slot" status=UNKNOWN known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
            else
                meta_init_slot "$_slot" || return 1
            fi
            rm -rf "$DURANIUM_BOOT_MNT/duranium/boot/$_slot" 2>/dev/null || true
        done
        meta_update_global active_slot="" pending_slot="" fallback_slot="" last_known_good_slot="" update_in_progress="" || return 1
        bootloader_sync || return 1
        dur_log "factory reset: OS slots invalidated; STATE preserved"
    fi

    if [ "$_mode" = "state" ] || [ "$_mode" = "full" ]; then
        if dur_is_mounted "$DURANIUM_STATE_MNT"; then
            dur_umount "$DURANIUM_STATE_MNT" || return 1
        fi
        backend_state_format || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
        if [ "$DURANIUM_BACKEND" = "dir" ]; then
            STATE_SCHEMA_DECLARED=1
            state_init_layout "$DURANIUM_STATE_MNT" || return 1
        else
            backend_mount_state "$DURANIUM_STATE_MNT" rw || return 1
            STATE_SCHEMA_DECLARED=1
            state_init_layout "$DURANIUM_STATE_MNT" || return 1
        fi
        dur_log "factory reset: STATE wiped and recreated"
    fi
    return 0
}
