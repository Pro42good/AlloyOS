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
    local _confirmed _path _pending _slot
    _slot=$1
    _pending=$2
    _confirmed=${3:-0}
    _path="$DURANIUM_RUN/boot.env"
    dur_mkdir "$DURANIUM_RUN" || return 1
    dur_atomic_write_text "$_path" "slot=$_slot
boot_id=$(dur_boot_id)
pending=$_pending
confirmed=$_confirmed
session=0
crash=0
clean=0
booted_at=$(dur_timestamp)"
    sync 2>/dev/null || true
}

slot_boot_env_field() {
    # slot_boot_env_field <field> - read one field of the current boot record.
    [ -r "$DURANIUM_RUN/boot.env" ] || return 1
    sed -n "s/^$1=//p" "$DURANIUM_RUN/boot.env" | head -n 1
    return 0
}

slot_boot_env_set() {
    # slot_boot_env_set <confirmed|session|crash|clean> <0|1>
    # Targeted update of one per-boot flag, preserving the rest of the file.
    local _k _path _v
    _k=$1
    _v=$2
    case "$_k" in confirmed|session|crash|clean) ;; *) return 1 ;; esac
    _path="$DURANIUM_RUN/boot.env"
    [ -r "$_path" ] || return 1
    sed "s/^${_k}=.*/${_k}=${_v}/" "$_path" > "$_path.new.$$" || {
        rm -f "$_path.new.$$"
        return 1
    }
    sync 2>/dev/null || true
    mv -f "$_path.new.$$" "$_path" || {
        rm -f "$_path.new.$$"
        return 1
    }
    return 0
}

# Per-slot durable record of the most recent userland boot, used for crash
# detection on the next boot. Best effort: never fails the caller's boot.
slot_boot_state_file() {
    printf '%s/duranium/boot/%s.state\n' "$DURANIUM_STATE_MNT" "$1"
}

slot_boot_state_field() {
    local _f
    _f=$(slot_boot_state_file "$1") || return 1
    [ -r "$_f" ] || return 1
    sed -n "s/^$2=//p" "$_f" | head -n 1
    return 0
}

slot_boot_state_write() {
    # slot_boot_state_write <slot> <boot_id> <pending> <confirmed>
    #                       <session> <crash> <clean>
    local _dir _f _slot
    _slot=$1
    _f=$(slot_boot_state_file "$_slot") || return 1
    _dir=$(dirname "$_f")
    dur_mkdir "$_dir" || return 1
    dur_atomic_write_text "$_f" "slot=$_slot
boot_id=$2
pending=$3
confirmed=$4
session=$5
crash=$6
clean=$7
updated_at=$(dur_timestamp)"
}

slot_boot_state_sync() {
    # Mirror the current boot.env flags into the durable STATE record.
    # $2 is the clean-shutdown value (boot-clean sets it to 1).
    local _clean _confirmed _crash _pending _session _slot
    _slot=$1
    _clean=$2
    _pending=$(slot_boot_env_field pending)
    _confirmed=$(slot_boot_env_field confirmed)
    _session=$(slot_boot_env_field session)
    _crash=$(slot_boot_env_field crash)
    slot_boot_state_write "$_slot" "$(dur_boot_id)" "${_pending:-0}" \
        "${_confirmed:-0}" "${_session:-0}" "${_crash:-0}" "$_clean"
}

slot_journal() {
    # Append-only evidence journal (boot confirmations, sign-ins, crashes,
    # clean shutdowns, detections). Never fails the caller.
    [ -d "$DURANIUM_STATE_MNT/duranium" ] || return 0
    printf '%s %s\n' "$(dur_timestamp)" "$1" \
        >> "$DURANIUM_STATE_MNT/duranium/bootlog" 2>/dev/null || true
    return 0
}

# Boot-confirmation handshake.
#
# Booting a slot and proving the boot usable are different events:
#   * systemd-boot counting covers failures before userland;
#   * a kernel that loads but freezes partway through userland looks
#     identical to a completed boot to anything that only reads metadata.
# The booted OS therefore confirms its own boot in two stages, and
# mark-good refuses a pending slot whose current boot was never confirmed.
slot_boot_confirmed() {
    [ "$(slot_boot_env_field slot)" = "$1" ] || return 1
    [ "$(slot_boot_env_field confirmed)" = "1" ] || return 1
    return 0
}

slot_boot_confirm() {
    local _arg _slot
    _slot=$(slot_booted) || {
        dur_err "boot-confirm: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "boot-confirm: invalid slot"; return 1; }
    _arg=${1:-}
    if [ -n "$_arg" ]; then
        dur_is_slot "$_arg" || { dur_err "boot-confirm: invalid slot"; return 1; }
        [ "$_arg" = "$_slot" ] || {
            dur_err "boot-confirm: slot $_arg is not the currently booted slot ($_slot)"
            return 1
        }
    fi
    [ -r "$DURANIUM_RUN/boot.env" ] || {
        dur_err "boot-confirm: no boot record for this boot; boot-record must run first"
        return 1
    }
    [ "$(slot_boot_env_field slot)" = "$_slot" ] || {
        dur_err "boot-confirm: boot record is for slot $(slot_boot_env_field slot), not $_slot"
        return 1
    }
    # Crash detection: if the previous boot of this slot reached userland
    # but never shut down cleanly, that is evidence of a crash/power loss.
    slot_boot_detect_unclean "$_slot"
    # Set only the confirmed flag. A full rewrite here would reset the
    # crash/session flags recorded earlier in the same boot (e.g. by
    # session-crash) and erase the evidence mark-good relies on.
    slot_boot_env_set confirmed 1 || return 1
    slot_boot_state_sync "$_slot" 0 || true
    slot_journal "CONFIRM slot=$_slot boot_id=$(dur_boot_id) pending=$(slot_boot_env_field pending)"
    return 0
}

# Sign-in gate (stage 2). The desktop/sign-in manager calls this once the
# user environment is actually up after sign-in. V1 ships the API as a
# stub: nothing in the fixture calls it, and mark-good only requires it
# when DURANIUM_REQUIRE_SESSION=1.
slot_session_confirm() {
    local _arg _slot
    _slot=$(slot_booted) || {
        dur_err "session-confirm: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "session-confirm: invalid slot"; return 1; }
    _arg=${1:-}
    if [ -n "$_arg" ]; then
        dur_is_slot "$_arg" || { dur_err "session-confirm: invalid slot"; return 1; }
        [ "$_arg" = "$_slot" ] || {
            dur_err "session-confirm: slot $_arg is not the currently booted slot ($_slot)"
            return 1
        }
    fi
    [ "$(slot_boot_env_field slot)" = "$_slot" ] || {
        dur_err "session-confirm: boot record is for slot $(slot_boot_env_field slot), not $_slot"
        return 1
    }
    [ "$(slot_boot_env_field confirmed)" = "1" ] || {
        dur_err "session-confirm: boot is not confirmed; boot-confirm must run first"
        return 1
    }
    slot_boot_env_set session 1 || return 1
    slot_boot_state_sync "$_slot" 0 || true
    slot_journal "SESSION slot=$_slot boot_id=$(dur_boot_id)"
    return 0
}

# Crash report from the booted OS: the user environment crashed after
# sign-in. A pending slot is immediately BAD (the OS itself judged the
# candidate unusable; invariant: no automatic retry). A GOOD slot is
# recorded but never demoted: GOOD changes only through explicit
# operator action (V1 policy).
slot_session_crash() {
    local _reason _slot
    _slot=$(slot_booted) || {
        dur_err "session-crash: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "session-crash: invalid slot"; return 1; }
    _reason=${1:-unspecified}
    _reason=$(printf '%s' "$_reason" | tr '\r\n\t' '   ')
    [ -n "$_reason" ] || _reason=unspecified
    slot_boot_env_set crash 1 || true
    slot_boot_state_sync "$_slot" 0 || true
    slot_journal "CRASH slot=$_slot boot_id=$(dur_boot_id) reason=$_reason"
    meta_load_global || return 1
    if [ "$MG_pending_slot" = "$_slot" ]; then
        if slot_mark_bad "$_slot"; then
            slot_log "session crash on pending slot $_slot marked BAD"
            return 0
        fi
        return 1
    fi
    slot_log "session crash recorded for slot $_slot (status unchanged)"
    return 0
}

# Called by the OS on a clean shutdown. The next boot uses the durable
# record to distinguish a clean restart from a crash/power loss.
slot_boot_clean() {
    local _slot
    _slot=$(slot_booted) || {
        dur_err "boot-clean: cannot determine the booted slot"
        return 1
    }
    dur_is_slot "$_slot" || { dur_err "boot-clean: invalid slot"; return 1; }
    slot_boot_env_set clean 1 || true
    slot_boot_state_sync "$_slot" 1 || true
    slot_journal "CLEAN slot=$_slot boot_id=$(dur_boot_id)"
    return 0
}

slot_boot_detect_unclean() {
    local _prev_boot _prev_clean _prev_confirmed _prev_session _slot
    _slot=$1
    _prev_boot=$(slot_boot_state_field "$_slot" boot_id)
    [ -n "$_prev_boot" ] || return 0
    [ "$_prev_boot" != "$(dur_boot_id)" ] || return 0
    _prev_clean=$(slot_boot_state_field "$_slot" clean)
    [ "$_prev_clean" = "1" ] && return 0
    _prev_confirmed=$(slot_boot_state_field "$_slot" confirmed)
    _prev_session=$(slot_boot_state_field "$_slot" session)
    case "$_prev_confirmed$_prev_session" in
        *1*) ;;
        *) return 0 ;;
    esac
    dur_warn "previous boot of slot $_slot (boot ${_prev_boot}) reached userland but did not shut down cleanly"
    slot_journal "DETECTED slot=$_slot boot_id=$_prev_boot unclean_shutdown=1"
    return 0
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
                    # A PENDING slot that is not named by the pending pointer
                    # is a stale orphan: its +N entry outranks the GOOD active
                    # slot and hijacks every boot, and nothing will ever
                    # confirm it. The only legitimate pointer-less window is
                    # mid-update, which update_in_progress covers (and
                    # slot_reconcile_interrupted_update already handled).
                    if [ "$MG_pending_slot" != "$_slot" ] && [ -z "$MG_update_in_progress" ]; then
                        dur_warn "pending slot $_slot is not the pending slot; marking stale orphan BAD"
                        meta_update_slot "$_slot" status=BAD known_good=0 boot_attempts_remaining=0 pending_boot_id= || return 1
                        _changed=1
                        continue
                    fi
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
                    # A GOOD slot must have a plain counterless entry. A
                    # missing entry, or a leftover boot counter from a crash
                    # between the mark-good metadata commit and
                    # bootloader_sync, is repaired by the final sync.
                    _estate=$(bootloader_entry_state "$_slot")
                    case "$_estate" in
                        good) ;;
                        *) _changed=1 ;;
                    esac
                    ;;
            esac
        fi
    done

    # A pending pointer must name a PENDING slot. GOOD means mark-good
    # committed partially: complete it safely. Anything else (BAD, UNKNOWN,
    # invalid metadata) is a stale pointer, e.g. global metadata restored
    # from an older backup; left alone it would block all future updates,
    # so clear it.
    if [ -n "$MG_pending_slot" ]; then
        if meta_load_slot "$MG_pending_slot"; then
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
            elif [ "$MS_status" != "PENDING" ]; then
                dur_warn "pending slot $MG_pending_slot is $MS_status; clearing stale pending pointer"
                meta_update_global pending_slot="" || return 1
                meta_load_global || return 1
                _changed=1
            fi
        else
            dur_warn "pending slot $MG_pending_slot has invalid metadata; clearing stale pending pointer"
            meta_update_global pending_slot="" || return 1
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

# Verify the slot partition against MS_image_sha256 (slot metadata must be
# loaded). Used at boot time when enabled and always before mark-good.
#
# The hash recorded at install time covers exactly the installed image bytes,
# not the partition: partitions are provisioned with headroom, and the
# partition tail contains whatever was there before. Hash the recorded
# image_size; fall back to the device size only for metadata that predates
# image_size (dir-backend slots, whose file is exactly the image).
slot_verify_root() {
    local _dev _r _size _slot
    _slot=$1
    _dev=$(backend_slot_dev "$_slot") || return 1
    if dur_is_uint "${MS_image_size:-}" && [ "$MS_image_size" -gt 0 ]; then
        _size=$MS_image_size
    else
        _size=$(backend_part_size "$_dev") || return 1
    fi
    _r=$(dur_sha256_prefix "$_dev" "$_size") || return 1
    [ "$_r" = "$MS_image_sha256" ] || { DURANIUM_LAST_ERROR="root image hash mismatch for $_slot"; return 1; }
    return 0
}

slot_boot_verify() {
    local _dev _i _initramfs _k _kernel _r _size _slot
    _slot=$1
    backend_init || return 1
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
        slot_verify_root "$_slot" || return 1
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
        # A GOOD fallback was selected and synced. Rebooting lets systemd-boot
        # pick the fallback entry (sort-key 20/30 beats recovery's 90);
        # recovery is for when no normal slot remains (docs/03).
        if [ -n "$_fallback" ]; then
            return 0
        fi
        return 2
    fi
    return 2
}

slot_mark_good() {
    local _boot_id _booted _fallback _old_active _old_fallback _slot
    # Resolve slot devices (mark-good may run outside any command that
    # already initialized the backend; in the guest the device environment
    # is unset and devices must be resolved by label here).
    backend_init || { dur_err "mark-good: $DURANIUM_LAST_ERROR"; return 1; }
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
    [ "$_boot_id" != "unknown" ] || {
        dur_err "mark-good: kernel boot ID is unavailable; refusing to confirm"
        return 1
    }
    [ -n "$MS_pending_boot_id" ] || {
        dur_err "mark-good: slot $_slot has no recorded boot ID"
        return 1
    }
    [ "$MS_pending_boot_id" = "$_boot_id" ] || {
        dur_err "mark-good: boot ID does not match the pending boot"
        return 1
    }
    # Stage 1 of the handshake: the booted OS must have confirmed this boot.
    # A kernel that freezes partway through userland never confirms, and a
    # premature mark-good without the OS handshake is refused.
    if ! slot_boot_confirmed "$_slot"; then
        dur_err "mark-good: the booted OS has not confirmed this boot (duranium boot-confirm)"
        return 1
    fi
    # Stage 2 (the sign-in gate): required only when the deployment enables
    # it. V1 defaults to off; the Alloy desktop sets DURANIUM_REQUIRE_SESSION=1
    # so a pending slot is confirmed only after the user environment is up.
    if [ "${DURANIUM_REQUIRE_SESSION:-0}" = "1" ] && \
       [ "$(slot_boot_env_field session)" != "1" ]; then
        dur_err "mark-good: the session has not confirmed sign-in for this boot (duranium session-confirm)"
        return 1
    fi
    # A boot whose environment reported a crash must not be confirmed.
    [ "$(slot_boot_env_field crash)" != "1" ] || {
        dur_err "mark-good: this boot recorded a session crash; refusing to confirm"
        return 1
    }
    # Confirm the root image still matches the hash recorded at install
    # time. Kernel/initramfs are re-verified on every boot; the root image
    # otherwise is not, and mark-good is the one-shot moment to check it.
    if ! slot_verify_root "$_slot"; then
        dur_err "mark-good: ${DURANIUM_LAST_ERROR:-root image verification failed for slot $_slot}"
        return 1
    fi
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
    local _active _fallback _force _last _pending _slot
    _slot=$1
    _force=${2:-0}
    dur_is_slot "$_slot" || { dur_err "select: invalid slot"; return 1; }
    meta_load_global || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    if [ "$MS_status" != "GOOD" ]; then
        if [ "$_force" != "1" ]; then
            dur_err "select: slot $_slot is $MS_status, not GOOD (use --force only in recovery)"
            return 1
        fi
        # Force is an operator decision made from recovery, and it is only
        # meaningful for a slot with trusted content: re-arm it as a fresh
        # pending transaction (fresh attempts, pending pointer, new +N
        # entry). UNKNOWN slots have no trusted image and stay refused.
        recovery_require_context || {
            dur_err "select: --force is only available in the recovery environment"
            return 1
        }
        case "$MS_status" in
            PENDING|BAD) ;;
            *) dur_err "select: cannot force-select a $MS_status slot"; return 1 ;;
        esac
    fi
    _active=$MG_active_slot
    _fallback=$MG_fallback_slot
    _last=$MG_last_known_good_slot
    _pending=$MG_pending_slot
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
        _pending=""
    else
        # Forced selection is a recovery-operator decision to give a slot
        # another chance. Re-arm it as a fresh pending transaction (fresh
        # attempts, pending pointer, new +N entry): merely pointing active at
        # a non-GOOD slot would write metadata that no boot flow honors.
        meta_update_slot "$_slot" status=PENDING known_good=0 \
            boot_attempts_remaining="$MS_max_boot_attempts" \
            pending_boot_id= || return 1
        [ "$_active" = "$_slot" ] && _active=""
        [ "$_fallback" = "$_slot" ] && _fallback=""
        [ "$_last" = "$_slot" ] && _last=""
        _pending=$_slot
    fi
    meta_update_global active_slot="$_active" pending_slot="$_pending" fallback_slot="$_fallback" last_known_good_slot="$_last" || return 1
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
