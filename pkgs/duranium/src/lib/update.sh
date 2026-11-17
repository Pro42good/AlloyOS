#!/bin/sh
# Offline, local A/B update installation.
#
# Invariants:
#   * The active (booted, GOOD) slot is never written.
#   * The inactive slot is marked UNKNOWN before the first destructive write.
#   * The signed manifest and every payload hash are verified before activation.
#   * The inactive slot becomes PENDING only after read-back verification.
#   * Any failure before that point leaves the current boot selection intact.
#   * A crash leaves update_in_progress set; the next boot marks the target BAD.

update_log() {
    local _msg
    _msg=$1
    if [ -d "$DURANIUM_STATE_MNT/duranium" ]; then
        printf '%s %s\n' "$(dur_timestamp)" "$_msg" >> "$DURANIUM_STATE_MNT/duranium/updates.log" 2>/dev/null || true
    fi
}

update_recovery_context() {
    [ "${DURANIUM_RECOVERY:-0}" = "1" ] && return 0
    [ -e "$DURANIUM_RUN/recovery" ] && return 0
    return 1
}

update_check_profile() {
    local _allow
    _allow=$1
    if [ "$MF_profile" = "$DURANIUM_PROFILE" ]; then
        return 0
    fi
    if [ "$_allow" = "1" ] && [ "$DURANIUM_PROFILE" = "dev" ] && [ "$DURANIUM_DEV_OVERRIDE" = "1" ]; then
        dur_warn "development profile override: system=$DURANIUM_PROFILE artifact=$MF_profile"
        return 0
    fi
    DURANIUM_LAST_ERROR="profile mismatch: system=$DURANIUM_PROFILE artifact=$MF_profile"
    return 1
}

update_check_architecture() {
    [ "$MF_architecture" = "$DURANIUM_ARCH" ] || {
        DURANIUM_LAST_ERROR="architecture mismatch: system=$DURANIUM_ARCH artifact=$MF_architecture"
        return 1
    }
    return 0
}

update_check_hardware() {
    [ "$MF_hardware_target" = "$DURANIUM_HARDWARE_TARGET" ] || {
        DURANIUM_LAST_ERROR="hardware target mismatch: system=$DURANIUM_HARDWARE_TARGET artifact=$MF_hardware_target"
        return 1
    }
    return 0
}

update_check_state_schema() {
    local _current
    _current=0
    if dur_is_mounted "$DURANIUM_STATE_MNT" || [ "$DURANIUM_BACKEND" = "dir" ]; then
        _current=$(state_schema_get)
    fi
    [ -n "$_current" ] || _current=0
    if [ "$_current" -gt 0 ] && [ "$MF_state_schema_required" -lt "$_current" ]; then
        DURANIUM_LAST_ERROR="state downgrade rejected: STATE is schema $_current, artifact requires $MF_state_schema_required"
        return 1
    fi
    if [ "$MF_state_schema_required" -gt "$_current" ]; then
        # A rollback slot is expected to remain available. Only additive,
        # backward-compatible migrations are allowed in that situation.
        if [ "$MF_state_schema_backward_compatible" != "1" ] || [ "$MF_rollback_compatible" != "1" ]; then
            DURANIUM_LAST_ERROR="artifact requires state schema $MF_state_schema_required but migration is not rollback-safe"
            return 1
        fi
    fi
    return 0
}

update_verify_compatibility() {
    local _allow
    _allow=${1:-0}
    update_check_profile "$_allow" || return 1
    update_check_architecture || return 1
    update_check_hardware || return 1
    update_check_state_schema || return 1
    return 0
}

update_verify() {
    local _allow _dir
    _dir=$1
    _allow=${2:-0}
    manifest_verify "$_dir" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    update_verify_compatibility "$_allow" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    printf 'verified: %s (%s, profile=%s, %s)\n' "$MF_build_id" "$MF_alloy_version" "$MF_profile" "$MF_architecture"
    return 0
}

update_lock() {
    local _lock _old
    _lock="$DURANIUM_RUN/update.lock"
    if [ -d "$_lock" ]; then
        _old=$(cat "$_lock/pid" 2>/dev/null || true)
        if [ -n "$_old" ] && [ -d "/proc/$_old" ]; then
            DURANIUM_LAST_ERROR="another update is in progress (pid $_old)"
            return 1
        fi
        rm -rf "$_lock" 2>/dev/null || true
    fi
    mkdir -p "$_lock" 2>/dev/null || {
        DURANIUM_LAST_ERROR="cannot create update lock"
        return 1
    }
    printf '%s\n' "$$" > "$_lock/pid"
    UPDATE_LOCK="$_lock"
    return 0
}

update_unlock() {
    if [ -n "${UPDATE_LOCK:-}" ] && [ -d "$UPDATE_LOCK" ]; then
        rm -rf "$UPDATE_LOCK" 2>/dev/null || true
    fi
    UPDATE_LOCK=""
}

update_materialize_payload() {
    local _dir _hash _out
    _dir=$1
    case "$MF_system_image_compression" in
        none)
            printf '%s\n' "$_dir/$MF_system_image"
            ;;
        gzip)
            _out="$DURANIUM_TMP/system.img"
            gzip -dc "$_dir/$MF_system_image" > "$_out" || {
                DURANIUM_LAST_ERROR="cannot decompress system image"
                return 1
            }
            _hash=$(dur_sha256_file "$_out") || return 1
            if [ "$_hash" != "$MF_system_image_sha256" ]; then
                DURANIUM_LAST_ERROR="decompressed payload hash mismatch"
                return 1
            fi
            printf '%s\n' "$_out"
            ;;
    esac
}

update_target_mounted() {
    local _dev
    _dev=$1
    [ -r /proc/mounts ] || return 1
    awk -v d="$_dev" '$1 == d { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts
}

update_copy_boot_artifacts() {
    local _artdir _ih _kh _slot
    _slot=$1
    _artdir=$2
    backend_boot_write "duranium/boot/$_slot/vmlinuz" "$_artdir/$MF_boot_kernel" || {
        DURANIUM_LAST_ERROR="failed to write boot kernel for $_slot"
        return 1
    }
    backend_boot_write "duranium/boot/$_slot/initramfs" "$_artdir/$MF_boot_initramfs" || {
        DURANIUM_LAST_ERROR="failed to write initramfs for $_slot"
        return 1
    }
    backend_boot_write "duranium/boot/$_slot/manifest.txt" "$_artdir/manifest.txt" || return 1
    backend_boot_write "duranium/boot/$_slot/manifest.sig" "$_artdir/manifest.sig" || return 1
    _kh=$(backend_boot_hash "duranium/boot/$_slot/vmlinuz") || return 1
    _ih=$(backend_boot_hash "duranium/boot/$_slot/initramfs") || return 1
    [ "$_kh" = "$MF_boot_kernel_sha256" ] || { DURANIUM_LAST_ERROR="boot kernel read-back hash mismatch"; return 1; }
    [ "$_ih" = "$MF_boot_initramfs_sha256" ] || { DURANIUM_LAST_ERROR="initramfs read-back hash mismatch"; return 1; }
    return 0
}

update_abort() {
    local _active _fallback _last _pending _target _why
    _target=$1
    _why=$2
    dur_err "update aborted: $_why"
    if meta_load_slot "$_target"; then
        meta_update_slot "$_target" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || true
    fi
    if meta_load_global; then
        _active=$MG_active_slot
        _fallback=$MG_fallback_slot
        _last=$MG_last_known_good_slot
        _pending=$MG_pending_slot
        [ "$_pending" = "$_target" ] && _pending=""
        if [ "$_active" = "$_target" ]; then
            _active=""
            if [ -n "$_fallback" ] && [ "$_fallback" != "$_target" ] && slot_is_good "$_fallback"; then
                _active=$_fallback
            elif [ -n "$_last" ] && [ "$_last" != "$_target" ] && slot_is_good "$_last"; then
                _active=$_last
            fi
        fi
        [ "$_fallback" = "$_target" ] && _fallback=$_active
        [ "$_last" = "$_target" ] && _last=$_fallback
        meta_update_global active_slot="$_active" pending_slot="$_pending" fallback_slot="$_fallback" last_known_good_slot="$_last" update_in_progress="" || true
    fi
    bootloader_sync || true
    update_log "update aborted target=$_target reason=$_why"
    return 1
}

update_install() {
    local _active _allow_profile _booted _dir _newactive _other _payload _phash _psize _reboot _recovery_mode _rhash _target _target_arg _tdev _tsize
    _dir=$1
    _allow_profile=${2:-0}
    _reboot=${3:-0}
    _target_arg=${4:-}
    _recovery_mode=${5:-0}

    manifest_verify "$_dir" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    update_verify_compatibility "$_allow_profile" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }

    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    _booted=$(slot_booted 2>/dev/null || true)

    if [ "$_recovery_mode" = "1" ]; then
        update_recovery_context || { dur_err "update: not in recovery"; return 1; }
        [ -n "$_target_arg" ] || { dur_err "update: recovery install requires --target A|B"; return 1; }
        _target=$_target_arg
        dur_is_slot "$_target" || { dur_err "update: invalid target slot"; return 1; }
        # Reinstalling the currently active slot must first move the active
        # pointer to another GOOD slot (or to none). active == pending would be
        # invalid metadata.
        if [ "$MG_active_slot" = "$_target" ]; then
            _newactive=""
            if [ -n "$MG_fallback_slot" ] && [ "$MG_fallback_slot" != "$_target" ] && slot_is_good "$MG_fallback_slot"; then
                _newactive=$MG_fallback_slot
            elif [ -n "$MG_last_known_good_slot" ] && [ "$MG_last_known_good_slot" != "$_target" ] && slot_is_good "$MG_last_known_good_slot"; then
                _newactive=$MG_last_known_good_slot
            else
                _other=$(dur_other_slot "$_target")
                if slot_is_good "$_other"; then _newactive=$_other; fi
            fi
            meta_update_global active_slot="$_newactive" pending_slot="" update_in_progress="" || {
                dur_err "update: cannot move active pointer away from reinstall target"
                return 1
            }
            meta_load_global || return 1
        fi
    else
        [ -n "$MG_pending_slot" ] && { dur_err "update: a pending update already exists ($MG_pending_slot)"; return 1; }
        [ -z "$MG_update_in_progress" ] || { dur_err "update: an interrupted update needs reconciliation"; return 1; }
        _active=$MG_active_slot
        dur_is_slot "$_active" || { dur_err "update: no active slot in global metadata"; return 1; }
        if [ -n "$_booted" ] && [ "$_booted" != "$_active" ]; then
            dur_err "update: running slot $_booted is not the active GOOD slot $_active"
            return 1
        fi
        meta_load_slot "$_active" || { dur_err "update: active slot metadata invalid"; return 1; }
        [ "$MS_status" = "GOOD" ] || { dur_err "update: active slot $_active is $MS_status, not GOOD"; return 1; }
        _target=$(dur_other_slot "$_active") || return 1
        [ "$_target" != "$_active" ] || { dur_err "update: refusing to write the active slot"; return 1; }
    fi

    _tdev=$(backend_slot_dev "$_target") || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    if update_target_mounted "$_tdev"; then
        dur_err "update: target slot device is mounted: $_tdev"
        return 1
    fi
    _tsize=$(backend_part_size "$_tdev") || { dur_err "update: cannot determine target partition size"; return 1; }
    if [ "$MF_system_image_size" -gt "$_tsize" ]; then
        dur_err "update: image does not fit in target ($MF_system_image_size > $_tsize)"
        return 1
    fi

    _payload=$(update_materialize_payload "$_dir") || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    _psize=$(wc -c < "$_payload" | tr -d ' ')
    [ "$_psize" = "$MF_system_image_size" ] || { dur_err "update: materialized payload size mismatch"; return 1; }
    _phash=$(dur_sha256_file "$_payload") || return 1
    [ "$_phash" = "$MF_system_image_sha256" ] || { dur_err "update: payload hash mismatch"; return 1; }

    update_lock || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    trap 'update_unlock' EXIT INT TERM

    update_log "update start target=$_target build=$MF_build_id allow_profile=$_allow_profile recovery=$_recovery_mode"
    dur_log "installing $MF_build_id into slot $_target (active selection untouched)"

    # Phase 1: make the target explicitly non-bootable and record the
    # transaction. If power fails from here on, the next boot knows the target
    # is dirty and will mark it BAD.
    if ! meta_update_slot "$_target" status=UNKNOWN known_good=0 boot_attempts_remaining=0 pending_boot_id=; then
        update_abort "$_target" "cannot mark target UNKNOWN"
        return 1
    fi
    if ! meta_update_global update_in_progress="$_target" pending_slot=""; then
        update_abort "$_target" "cannot record update transaction"
        return 1
    fi
    if ! bootloader_sync; then
        update_abort "$_target" "cannot remove old target boot entry"
        return 1
    fi

    # Phase 2: write only the inactive slot.
    if ! backend_write_image "$_target" "$_payload" "$MF_system_image_size"; then
        update_abort "$_target" "${DURANIUM_LAST_ERROR:-write failed}"
        return 1
    fi
    if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ "${DURANIUM_TEST_FAIL_AT:-}" = "readback" ]; then
        update_abort "$_target" "injected read-back failure"
        return 1
    fi
    _rhash=$(backend_readback_hash "$_target" "$MF_system_image_size") || {
        update_abort "$_target" "read-back failed"
        return 1
    }
    if [ "$_rhash" != "$MF_system_image_sha256" ]; then
        update_abort "$_target" "read-back SHA-256 mismatch"
        return 1
    fi
    if ! backend_fsck_slot "$_target"; then
        update_abort "$_target" "filesystem check failed"
        return 1
    fi

    # Phase 3: slot-owned kernel and initramfs. The active slot's boot files
    # are never touched.
    if ! update_copy_boot_artifacts "$_target" "$_dir"; then
        update_abort "$_target" "${DURANIUM_LAST_ERROR:-boot artifact write failed}"
        return 1
    fi

    if [ "${DURANIUM_TEST_MODE:-0}" = "1" ] && [ "${DURANIUM_TEST_FAIL_AT:-}" = "metadata" ]; then
        update_abort "$_target" "injected metadata commit failure"
        return 1
    fi

    # Phase 4: only now is the inactive slot allowed to become PENDING.
    if ! meta_update_slot "$_target" \
        status=PENDING \
        alloy_version="$MF_alloy_version" \
        build_id="$MF_build_id" \
        image_sha256="$MF_system_image_sha256" \
        boot_kernel_sha256="$MF_boot_kernel_sha256" \
        boot_initramfs_sha256="$MF_boot_initramfs_sha256" \
        profile="$MF_profile" \
        architecture="$MF_architecture" \
        hardware_target="$MF_hardware_target" \
        state_schema="$MF_state_schema_required" \
        boot_attempts_remaining="$DURANIUM_MAX_BOOT_ATTEMPTS" \
        max_boot_attempts="$DURANIUM_MAX_BOOT_ATTEMPTS" \
        known_good=0 \
        pending_boot_id=""; then
        update_abort "$_target" "cannot commit PENDING metadata"
        return 1
    fi
    if ! meta_update_global pending_slot="$_target" update_in_progress=""; then
        update_abort "$_target" "cannot commit pending slot"
        return 1
    fi
    if ! bootloader_sync; then
        update_abort "$_target" "cannot write new boot entry"
        return 1
    fi

    update_log "update ready target=$_target build=$MF_build_id"
    update_unlock
    trap - EXIT INT TERM
    printf 'READY_TO_REBOOT slot=%s build=%s\n' "$_target" "$MF_build_id"
    if [ "$_reboot" = "1" ]; then
        if [ "$DURANIUM_TEST_MODE" = "1" ]; then
            sync 2>/dev/null || true
            poweroff -f 2>/dev/null || exit 0
        else
            sync 2>/dev/null || true
            reboot 2>/dev/null || true
        fi
    fi
    return 0
}
