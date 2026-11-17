#!/bin/sh
# Bootloader backends.
#
# systemd-boot is the V1 bootloader. It implements per-slot kernels using its
# native boot counting: an entry named "duranium-b+3.conf" gets three boot
# attempts; systemd-boot rewrites the suffix to "+2-1", "+1-2", "+0-3" and
# then skips it. The suffix is therefore boot-critical metadata that lives on
# BOOT, not in STATE.
#
# The fake backend mirrors the same filename semantics for unit tests.

bootloader_lower() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

bootloader_entry_base() {
    local _slot
    _slot=$(bootloader_lower "$1")
    printf 'duranium-%s\n' "$_slot"
}

bootloader_init() {
    dur_mkdir "$DURANIUM_ENTRIES_DIR" || return 1
    dur_mkdir "$DURANIUM_BOOT_FILES_DIR" || return 1
    return 0
}

bootloader_remove_slot() {
    local _base _f
    _base=$(bootloader_entry_base "$1") || return 1
    for _f in "$DURANIUM_ENTRIES_DIR/$_base"*.conf; do
        [ -e "$_f" ] && rm -f "$_f"
    done
    sync 2>/dev/null || true
    return 0
}

bootloader_entry_path() {
    local _base _f
    _base=$(bootloader_entry_base "$1") || return 1
    for _f in "$DURANIUM_ENTRIES_DIR/$_base"*.conf; do
        if [ -e "$_f" ]; then
            printf '%s\n' "$_f"
            return 0
        fi
    done
    return 1
}

# Prints "none", "good", or the numeric tries-left suffix.
bootloader_entry_state() {
    local _base _f _found _left _name _rest _slot _suffix
    _slot=$1
    _base=$(bootloader_entry_base "$_slot") || return 1
    _found=""
    for _f in "$DURANIUM_ENTRIES_DIR/$_base"*.conf; do
        [ -e "$_f" ] || continue
        if [ -n "$_found" ]; then
            printf 'duplicate\n'
            return 0
        fi
        _found=$_f
    done
    [ -n "$_found" ] || { printf 'none\n'; return 0; }
    _name=$(basename "$_found")
    _name=${_name%.conf}
    _rest=${_name#"$_base"}
    case "$_rest" in
        '') printf 'good\n' ;;
        +*)
            _suffix=${_rest#+}
            _left=${_suffix%%-*}
            dur_is_uint "$_left" || { printf 'malformed\n'; return 0; }
            printf '%s\n' "$_left"
            ;;
        *) printf 'malformed\n' ;;
    esac
    return 0
}

bootloader_read_attempts() {
    local _state
    _state=$(bootloader_entry_state "$1")
    case "$_state" in
        none) printf '0\n' ;;
        good) printf '%s\n' "$DURANIUM_MAX_BOOT_ATTEMPTS" ;;
        malformed|duplicate) return 1 ;;
        *) printf '%s\n' "$_state" ;;
    esac
    return 0
}

bootloader_write_entry() {
    local _name _path _text
    _name=$1
    _text=$2
    _path="$DURANIUM_ENTRIES_DIR/$_name"
    printf '%s\n' "$_text" | dur_atomic_write "$_path"
}

bootloader_slot_opts() {
    local _slot
    _slot=$1
    printf '%s duranium.slot=%s' "$DURANIUM_CONSOLE" "$_slot"
    if [ -n "$DURANIUM_EXTRA_CMDLINE" ]; then
        printf ' %s' "$DURANIUM_EXTRA_CMDLINE"
    fi
}

bootloader_write_slot_entry() {
    local _base _name _opts _slot _sortkey _suffix _text _title
    _slot=$1
    _suffix=$2
    _sortkey=$3
    _title=$4
    _base=$(bootloader_entry_base "$_slot") || return 1
    _name="$_base${_suffix}.conf"
    _opts=$(bootloader_slot_opts "$_slot")
    _text="title $_title
sort-key $_sortkey-$_base
linux /duranium/boot/$_slot/vmlinuz
initrd /duranium/boot/$_slot/initramfs
options $_opts"
    bootloader_write_entry "$_name" "$_text"
}

bootloader_write_recovery_entry() {
    local _text
    _text="title Alloy Recovery
sort-key 90-duranium-recovery
linux /duranium/boot/recovery/vmlinuz
initrd /duranium/boot/recovery/initramfs
options $DURANIUM_CONSOLE duranium.mode=recovery"
    bootloader_write_entry "duranium-recovery.conf" "$_text"
}

bootloader_write_loader_conf() {
    # No "default": systemd-boot picks the first entry by sort-key and boot
    # counting, which is exactly the selection order Duranium needs.
    backend_boot_write_text "loader/loader.conf" "timeout 1" || return 1
}

bootloader_sync() {
    local _active _attempts _global_ok _slot
    bootloader_init || return 1
    bootloader_remove_slot A || return 1
    bootloader_remove_slot B || return 1

    _global_ok=0
    if meta_load_global; then
        _global_ok=1
        _active=$MG_active_slot
    else
        dur_warn "bootloader_sync: global metadata invalid; only recovery entry will be written"
        _active=""
    fi

    for _slot in A B; do
        if ! meta_load_slot "$_slot"; then
            continue
        fi
        case "$MS_status" in
            PENDING)
                _attempts=$MS_boot_attempts_remaining
                if [ "$_attempts" -gt 0 ]; then
                    bootloader_write_slot_entry "$_slot" "+$_attempts" 10 \
                        "Alloy $_slot (pending, $_attempts attempts)" || return 1
                fi
                ;;
            GOOD)
                if [ "$_global_ok" = "1" ] && [ "$_active" = "$_slot" ]; then
                    bootloader_write_slot_entry "$_slot" "" 20 "Alloy $_slot (active, GOOD)" || return 1
                else
                    bootloader_write_slot_entry "$_slot" "" 30 "Alloy $_slot (GOOD)" || return 1
                fi
                ;;
            UNKNOWN|BAD)
                ;;
        esac
    done

    bootloader_write_recovery_entry || return 1
    bootloader_write_loader_conf || return 1
    sync 2>/dev/null || true
    return 0
}

bootloader_list() {
    local _f _sort _title
    for _f in "$DURANIUM_ENTRIES_DIR"/*.conf; do
        [ -e "$_f" ] || continue
        _sort=$(sed -n 's/^sort-key //p' "$_f" | head -n 1)
        _title=$(sed -n 's/^title //p' "$_f" | head -n 1)
        printf '%-45s sort=%-20s title=%s\n' "$(basename "$_f")" "${_sort:-none}" "${_title:-unknown}"
    done
}

# Unit-test bootloader. Mirrors systemd-boot's filename boot counting.
bootloader_fake_boot() {
    local _base _chosen _done _f _left _name _new _slot _sort _suffix _tmp
    _tmp="$DURANIUM_TMP/fake-entries.$$"
    : > "$_tmp"
    for _f in "$DURANIUM_ENTRIES_DIR"/*.conf; do
        [ -e "$_f" ] || continue
        _sort=$(sed -n 's/^sort-key //p' "$_f" | head -n 1)
        [ -n "$_sort" ] || _sort=50
        printf '%s %s\n' "$_sort" "$_f" >> "$_tmp"
    done
    sort "$_tmp" -o "$_tmp" || { rm -f "$_tmp"; return 1; }

    _chosen=""
    while IFS=' ' read -r _sort _f; do
        [ -n "$_f" ] || continue
        _name=$(basename "$_f")
        _name=${_name%.conf}
        case "$_name" in
            duranium-a*) _slot=A ;;
            duranium-b*) _slot=B ;;
            duranium-recovery*) _slot=recovery ;;
            *) continue ;;
        esac
        case "$_name" in
            *+*)
                _suffix=${_name#*+}
                _left=${_suffix%%-*}
                _done=0
                case "$_suffix" in
                    *-*) _done=${_suffix#*-} ;;
                esac
                dur_is_uint "$_left" || continue
                [ "$_left" -gt 0 ] || continue
                _base=${_name%%+*}
                _new="$_base+$((_left - 1))-$((_done + 1)).conf"
                mv "$_f" "$DURANIUM_ENTRIES_DIR/$_new" || { rm -f "$_tmp"; return 1; }
                _chosen=$_slot
                break
                ;;
            *)
                _chosen=$_slot
                break
                ;;
        esac
    done < "$_tmp"
    rm -f "$_tmp"
    [ -n "$_chosen" ] || { DURANIUM_LAST_ERROR="no bootable entry"; return 1; }
    mkdir -p "$DURANIUM_RUN" 2>/dev/null || true
    printf 'slot=%s\nboot_id=fake-%s\n' "$_chosen" "$(date +%s)" > "$DURANIUM_RUN/boot.env"
    printf '%s\n' "$_chosen"
}
