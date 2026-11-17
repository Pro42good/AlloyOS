#!/bin/sh
# Slot control: boot recording, transitions, reconciliation, status.
#
# Status semantics:
#   UNKNOWN - no trusted image; never booted automatically
#   PENDING - installed, unconfirmed; selected ahead of GOOD until attempts run out
#   GOOD    - confirmed healthy; may be active/fallback
#   BAD     - known broken; never booted automatically
#
# active_slot is the last confirmed GOOD (or recovery choice). The currently
# booted slot may be PENDING; "duranium status" distinguishes booted vs active.

slot_booted() {
    local _s
    if [ -r "$DURANIUM_RUN/boot.env" ]; then
        _s=$(sed -n 's/^slot=//p' "$DURANIUM_RUN/boot.env" | head -n 1)
        if dur_is_slot "$_s"; then
            printf '%s\n' "$_s"
            return 0
        fi
    fi
    _s=$(dur_cmdline_value duranium.slot 2>/dev/null || true)
    if dur_is_slot "$_s"; then
        printf '%s\n' "$_s"
        return 0
    fi
    return 1
}

slot_is_good() {
    meta_load_slot "$1" || return 1
    [ "$MS_status" = "GOOD" ]
}

slot_write_boot_env() {
    local _path _pending _slot
    _slot=$1
    _pending=$2
    _path="$DURANIUM_RUN/boot.env"
    dur_mkdir "$DURANIUM_RUN" || return 1
    printf 'slot=%s\nboot_id=%s\npending=%s\nbooted_at=%s\n' \
        "$_slot" "$(dur_boot_id)" "$_pending" "$(dur_timestamp)" > "$_path"
    sync 2>/dev/null || true
}

slot_log() {
    local _msg
    # Best-effort persistent log; never fail the operation because logging did.
    _msg=$1
    if [ -d "$DURANIUM_STATE_MNT/duranium" ]; then
        printf '%s %s\n' "$(dur_timestamp)" "$_msg" >> "$DURANIUM_STATE_MNT/duranium/duranium.log" 2>/dev/null || true
    fi
}

slot_reconcile_interrupted_update() {
    local _active _fallback _last _target
    # If a previous updater died after marking update_in_progress, the inactive
    # slot may be partially written. It must never be treated as GOOD.
    meta_load_global || return 1
    [ -n "$MG_update_in_progress" ] || return 0
    _target=$MG_update_in_progress
    dur_is_slot "$_target" || return 0
    dur_warn "interrupted update detected for slot $_target; marking it BAD"
    if meta_load_slot "$_target"; then
        meta_update_slot "$_target" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
    fi
    _active=$MG_active_slot
    _fallback=$MG_fallback_slot
    _last=$MG_last_known_good_slot
    if [ "$_active" = "$_target" ]; then
        _active=""
        if dur_is_slot "$_fallback" && slot_is_good "$_fallback"; then
            _active=$_fallback
        elif dur_is_slot "$_last" && slot_is_good "$_last"; then
            _active=$_last
        fi
    fi
    meta_update_global \
        active_slot="$_active" \
        fallback_slot="$_fallback" \
        last_known_good_slot="$_last" \
        pending_slot="" \
        update_in_progress="" || return 1
    bootloader_sync || return 1
    slot_log "interrupted update for $_target marked BAD"
    return 0
}

slot_reconcile() {
    local _active _changed _estate _fallback _last _new _old _slot
    # Idempotent boot-time reconciliation of bootloader counters and metadata.
    slot_reconcile_interrupted_update || return 1
    meta_load_global || return 1
    _changed=0

    # A pending slot whose entry ran out is BAD.
    for _slot in A B; do
        if meta_load_slot "$_slot"; then
            case "$MS_status" in
                PENDING)
                    _estate=$(bootloader_entry_state "$_slot")
                    case "$_estate" in
                        none)
                            dur_warn "pending slot $_slot has no boot entry; marking BAD"
                            meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
                            if [ "$MG_pending_slot" = "$_slot" ]; then
                                meta_update_global pending_slot="" || return 1
                                meta_load_global || return 1
                            fi
                            _changed=1
                            ;;
                        malformed|duplicate)
                            dur_warn "pending slot $_slot has malformed boot entry; marking BAD"
                            meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
                            if [ "$MG_pending_slot" = "$_slot" ]; then
                                meta_update_global pending_slot="" || return 1
                                meta_load_global || return 1
                            fi
                            _changed=1
                            ;;
                        good)
                            # Metadata says PENDING but the entry has no counter.
                            # Restore a counter from metadata; never grant
                            # unlimited attempts silently.
                            if [ "$MS_boot_attempts_remaining" -gt 0 ]; then
                                bootloader_sync || return 1
                            else
                                dur_warn "pending slot $_slot has a GOOD entry but no attempts; marking BAD"
                                meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
                                if [ "$MG_pending_slot" = "$_slot" ]; then
                                    meta_update_global pending_slot="" || return 1
                                    meta_load_global || return 1
                                fi
                                _changed=1
                            fi
                            ;;
                        *)
                            if dur_is_uint "$_estate"; then
                                if [ "$_estate" = "0" ]; then
                                    dur_warn "pending slot $_slot exhausted; marking BAD"
                                    meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
                                    if [ "$MG_pending_slot" = "$_slot" ]; then
                                        meta_update_global pending_slot="" || return 1
                                        meta_load_global || return 1
                                    fi
                                    _changed=1
                                elif [ "$_estate" != "$MS_boot_attempts_remaining" ]; then
                                    meta_update_slot "$_slot" boot_attempts_remaining="$_estate" || return 1
                                    _changed=1
                                fi
                            fi
                            ;;
                    esac
                    ;;
                GOOD)
                    # A missing entry is repaired by the final sync.
                    ;;
            esac
        fi
    done

    # A slot that is GOOD but still listed as pending means mark-good committed
    # partially. Complete it safely.
    if [ -n "$MG_pending_slot" ] && meta_load_slot "$MG_pending_slot"; then
        if [ "$MS_status" = "GOOD" ]; then
            _new=$MG_pending_slot
            _old=$MG_active_slot
            _fallback=$_old
            [ -n "$_fallback" ] || _fallback=$MG_last_known_good_slot
            if [ "$_fallback" = "$_new" ]; then
                _fallback=""
            fi
            if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
                _fallback=""
            fi
            meta_update_global active_slot="$_new" pending_slot="" fallback_slot="$_fallback" last_known_good_slot="$_new" || return 1
            meta_load_global || return 1
            _changed=1
        fi
    fi

    # Recover a usable active/fallback pair.
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
        if [ -n "$_active" ]; then
            meta_update_global active_slot="$_active" || return 1
            meta_load_global || return 1
            _changed=1
        fi
    fi

    _fallback=$MG_fallback_slot
    if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
        _fallback=""
    fi
    if [ -z "$_fallback" ] && [ -n "$MG_active_slot" ]; then
        _fallback=$MG_active_slot
        meta_update_global fallback_slot="$_fallback" || return 1
        meta_load_global || return 1
        _changed=1
    fi

    _last=$MG_last_known_good_slot
    if [ -n "$_last" ] && ! slot_is_good "$_last"; then
        _last=$MG_fallback_slot
        if [ -z "$_last" ]; then
            _last=$MG_active_slot
        fi
        meta_update_global last_known_good_slot="$_last" || return 1
        meta_load_global || return 1
        _changed=1
    fi

    if [ "$_changed" = "1" ]; then
        bootloader_sync || return 1
    fi
    return 0
}

slot_boot_record() {
    local _estate _slot
    _slot=$1
    dur_is_slot "$_slot" || return 2
    bootloader_init || return 2
    slot_reconcile_interrupted_update || return 2
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 2; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 2; }

    if [ "$MG_pending_slot" = "$_slot" ] && [ "$MS_status" = "PENDING" ]; then
        _estate=$(bootloader_entry_state "$_slot")
        case "$_estate" in
            none|malformed|duplicate)
                dur_err "pending slot $_slot booted without a valid entry ($_estate)"
                meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || true
                meta_update_global pending_slot="" || true
                bootloader_sync || true
                return 3
                ;;
            good)
                # A pending entry without a counter must not become immortal.
                if [ "$MS_boot_attempts_remaining" -gt 0 ]; then
                    bootloader_sync || return 3
                else
                    dur_err "pending slot $_slot has no attempts left"
                    meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || true
                    meta_update_global pending_slot="" || true
                    bootloader_sync || true
                    return 3
                fi
                ;;
            *)
                dur_is_uint "$_estate" || return 3
                if [ "$_estate" -eq 0 ]; then
                    dur_err "pending slot $_slot exhausted its attempts"
                    meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || true
                    meta_update_global pending_slot="" || true
                    bootloader_sync || true
                    return 3
                fi
                meta_update_slot "$_slot" boot_attempts_remaining="$_estate" pending_boot_id="$(dur_boot_id)" || return 3
                ;;
        esac
        slot_write_boot_env "$_slot" 1 || return 3
        slot_log "booting pending slot $_slot (attempts left $_estate)"
        return 0
    fi

    if [ "$MG_active_slot" = "$_slot" ]; then
        if [ "$MS_status" != "GOOD" ]; then
            dur_err "active slot $_slot is not GOOD (status=$MS_status)"
            return 2
        fi
        slot_write_boot_env "$_slot" 0 || return 3
        slot_log "booting active slot $_slot"
        return 0
    fi

    # Manual/inactive boot. Allow only a GOOD slot; everything else is unsafe.
    if [ "$MS_status" = "GOOD" ]; then
        slot_write_boot_env "$_slot" 0 || return 3
        slot_log "booting inactive GOOD slot $_slot"
        return 0
    fi

    dur_err "slot $_slot is not bootable (status=$MS_status, active=$MG_active_slot, pending=$MG_pending_slot)"
    return 2
}

slot_boot_verify() {
    local _dev _i _initramfs _k _kernel _r _size _slot
    _slot=$1
    meta_load_slot "$_slot" || return 1
    case "$MS_status" in
        GOOD|PENDING) ;;
        *) return 1 ;;
    esac
    _kernel="$DURANIUM_BOOT_MNT/duranium/boot/$_slot/vmlinuz"
    _initramfs="$DURANIUM_BOOT_MNT/duranium/boot/$_slot/initramfs"
    [ -r "$_kernel" ] || { DURANIUM_LAST_ERROR="missing boot kernel for $_slot"; return 1; }
    [ -r "$_initramfs" ] || { DURANIUM_LAST_ERROR="missing initramfs for $_slot"; return 1; }
    _k=$(dur_sha256_file "$_kernel") || return 1
    _i=$(dur_sha256_file "$_initramfs") || return 1
    [ "$_k" = "$MS_boot_kernel_sha256" ] || { DURANIUM_LAST_ERROR="kernel hash mismatch for $_slot"; return 1; }
    [ "$_i" = "$MS_boot_initramfs_sha256" ] || { DURANIUM_LAST_ERROR="initramfs hash mismatch for $_slot"; return 1; }
    if [ "$DURANIUM_VERIFY_ROOT_ON_BOOT" = "1" ] && [ "$DURANIUM_BACKEND" != "dir" ]; then
        _dev=$(backend_slot_dev "$_slot") || return 1
        _size=$(backend_part_size "$_dev") || return 1
        _r=$(dur_sha256_prefix "$_dev" "$_size") || return 1
        [ "$_r" = "$MS_image_sha256" ] || { DURANIUM_LAST_ERROR="root image hash mismatch for $_slot"; return 1; }
    fi
    return 0
}

slot_boot_fail() {
    local _fallback _last _slot _why
    _slot=$1
    _why=${2:-unknown}
    meta_load_global || return 2
    meta_load_slot "$_slot" || return 2
    dur_warn "boot failure for slot $_slot: $_why"
    slot_log "boot failure slot=$_slot reason=$_why"
    if [ "$MS_status" = "PENDING" ]; then
        if [ "$MS_boot_attempts_remaining" -gt 0 ]; then
            return 0
        fi
        meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 2
        if [ "$MG_pending_slot" = "$_slot" ]; then
            meta_update_global pending_slot="" || return 2
        fi
        bootloader_sync || return 2
        return 0
    fi
    if [ "$MS_status" = "GOOD" ] && [ "$MG_active_slot" = "$_slot" ]; then
        _fallback=$MG_fallback_slot
        _last=$MG_last_known_good_slot
        if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
            _fallback=""
        fi
        if [ -z "$_fallback" ] && [ -n "$_last" ] && [ "$_last" != "$_slot" ] && slot_is_good "$_last"; then
            _fallback=$_last
        fi
        meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 2
        if [ "$_fallback" = "$_slot" ]; then
            _fallback=""
        fi
        meta_update_global active_slot="$_fallback" fallback_slot="$_fallback" pending_slot="" || return 2
        bootloader_sync || return 2
        return 2
    fi
    return 2
}

slot_mark_good() {
    local _boot_id _booted _fallback _old_active _old_fallback _slot
    _slot=${1:-}
    [ -n "$_slot" ] || _slot=$(slot_booted) || {
        dur_err "mark-good: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "mark-good: invalid slot"; return 1; }
    _booted=$(slot_booted) || { dur_err "mark-good: cannot determine the booted slot"; return 1; }
    [ "$_booted" = "$_slot" ] || {
        dur_err "mark-good: slot $_slot is not the currently booted slot ($_booted)"
        return 1
    }
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    [ "$MG_pending_slot" = "$_slot" ] || {
        dur_err "mark-good: slot $_slot is not the pending slot"
        return 1
    }
    [ "$MS_status" = "PENDING" ] || {
        dur_err "mark-good: slot $_slot is $MS_status, not PENDING"
        return 1
    }
    _boot_id=$(dur_boot_id)
    [ -n "$MS_pending_boot_id" ] || {
        dur_err "mark-good: slot $_slot has no recorded boot ID"
        return 1
    }
    [ "$MS_pending_boot_id" = "$_boot_id" ] || {
        dur_err "mark-good: boot ID does not match the pending boot"
        return 1
    }
    if ! health_check; then
        dur_err "mark-good: health check failed; slot $_slot remains PENDING"
        return 1
    fi

    _old_active=$MG_active_slot
    _old_fallback=$MG_fallback_slot
    meta_update_slot "$_slot" status=GOOD known_good=1 boot_attempts_remaining=0 pending_boot_id= || return 1
    _fallback=$_old_active
    if [ -z "$_fallback" ] || [ "$_fallback" = "$_slot" ]; then
        _fallback=$_old_fallback
    fi
    if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
        _fallback=""
    fi
    meta_update_global \
        active_slot="$_slot" \
        pending_slot="" \
        fallback_slot="$_fallback" \
        last_known_good_slot="$_slot" || return 1
    bootloader_sync || return 1
    slot_log "slot $_slot marked GOOD; active=$_slot fallback=$_fallback"
    return 0
}

slot_mark_bad() {
    local _active _fallback _last _pending _slot _was_active
    _slot=${1:-}
    [ -n "$_slot" ] || _slot=$(slot_booted) || {
        dur_err "mark-bad: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "mark-bad: invalid slot"; return 1; }
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    _was_active=0
    [ "$MG_active_slot" = "$_slot" ] && _was_active=1
    meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
    _active=$MG_active_slot
    _fallback=$MG_fallback_slot
    _last=$MG_last_known_good_slot
    _pending=$MG_pending_slot
    if [ "$_pending" = "$_slot" ]; then
        _pending=""
    fi
    if [ "$_was_active" = "1" ]; then
        _active=""
        if [ -n "$_fallback" ] && [ "$_fallback" != "$_slot" ] && slot_is_good "$_fallback"; then
            _active=$_fallback
        elif [ -n "$_last" ] && [ "$_last" != "$_slot" ] && slot_is_good "$_last"; then
            _active=$_last
        fi
    fi
    if [ -n "$_fallback" ] && [ "$_fallback" = "$_slot" ]; then
        _fallback=$_active
    fi
    if [ -n "$_last" ] && [ "$_last" = "$_slot" ]; then
        _last=$_fallback
    fi
    meta_update_global active_slot="$_active" pending_slot="$_pending" fallback_slot="$_fallback" last_known_good_slot="$_last" || return 1
    bootloader_sync || return 1
    slot_log "slot $_slot marked BAD"
    return 0
}

slot_select() {
    local _active _fallback _force _last _slot
    _slot=$1
    _force=${2:-0}
    dur_is_slot "$_slot" || { dur_err "select: invalid slot"; return 1; }
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    if [ "$MS_status" != "GOOD" ] && [ "$_force" != "1" ]; then
        dur_err "select: slot $_slot is $MS_status, not GOOD (use --force only in recovery)"
        return 1
    fi
    _active=$MG_active_slot
    _fallback=$MG_fallback_slot
    _last=$MG_last_known_good_slot
    if [ "$MS_status" = "GOOD" ]; then
        _fallback=$_active
        if [ -z "$_fallback" ] || [ "$_fallback" = "$_slot" ]; then
            _fallback=$_last
        fi
        if [ -n "$_fallback" ] && ! slot_is_good "$_fallback"; then
            _fallback=""
        fi
        _last=$_slot
        _active=$_slot
    else
        _active=$_slot
    fi
    meta_update_global active_slot="$_active" fallback_slot="$_fallback" last_known_good_slot="$_last" || return 1
    bootloader_sync || return 1
    slot_log "selected slot $_slot active=$_active fallback=$_fallback"
    return 0
}

slot_status() {
    local _booted
    _booted=$(slot_booted 2>/dev/null || true)
    printf 'booted slot: %s\n' "${_booted:-unknown (not booted through Duranium)}"
    meta_load_global || {
        printf 'global metadata: INVALID/MISSING (%s)\n' "${DURANIUM_LAST_ERROR:-unknown}"
        meta_slot_summary A || true
        meta_slot_summary B || true
        return 1
    }
    printf 'active: %s  pending: %s  fallback: %s  last-known-good: %s\n' \
        "${MG_active_slot:-none}" "${MG_pending_slot:-none}" "${MG_fallback_slot:-none}" "${MG_last_known_good_slot:-none}"
    [ -z "$MG_update_in_progress" ] || printf 'update in progress: %s\n' "$MG_update_in_progress"
    printf 'global generation: %s (source: %s)\n' "$MG_generation" "$MG_SOURCE"
    meta_slot_summary A || true
    meta_slot_summary B || true
    return 0
}
