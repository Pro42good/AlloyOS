#!/bin/sh
# Persistent STATE model and schema migrations.
#
# Only explicitly declared paths persist. Image-owned defaults stay in the
# read-only system image. The minimal V1 allowlist is:
#   persistent: /home, /var/lib/alloy, /etc/alloy
# with /run, /tmp and /var/tmp ephemeral.

STATE_PERSISTENT=""
STATE_RECREATABLE=""
STATE_EPHEMERAL=""
STATE_SCHEMA_DECLARED=1

state_load_config() {
    local _class _conf _line _path _v
    STATE_PERSISTENT=""
    STATE_RECREATABLE=""
    STATE_EPHEMERAL=""
    STATE_SCHEMA_DECLARED=1
    _conf=$DURANIUM_STATE_CONF
    if [ ! -r "$_conf" ]; then
        # Built-in fallback must mirror src/etc/state.conf, otherwise a
        # recovery environment without the config would silently drop
        # STATE-backed directories.
        STATE_PERSISTENT="/home /var/lib/alloy /etc/alloy"
        STATE_RECREATABLE="/var/cache /var/log"
        STATE_EPHEMERAL="/run /tmp /var/tmp"
        return 0
    fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|\#*) continue ;;
            schema=*)
                _v=${_line#schema=}
                dur_is_uint "$_v" || { DURANIUM_LAST_ERROR="bad state schema"; return 1; }
                STATE_SCHEMA_DECLARED=$_v
                ;;
            path=*)
                _path=${_line#path=}
                _class=${_path##* }
                _path=${_path% *}
                case "$_class" in
                    persistent) STATE_PERSISTENT="$STATE_PERSISTENT $_path" ;;
                    recreatable) STATE_RECREATABLE="$STATE_RECREATABLE $_path" ;;
                    ephemeral) STATE_EPHEMERAL="$STATE_EPHEMERAL $_path" ;;
                    *) DURANIUM_LAST_ERROR="bad state class: $_class"; return 1 ;;
                esac
                case "$_path" in
                    /*) ;;
                    *) DURANIUM_LAST_ERROR="state path must be absolute: $_path"; return 1 ;;
                esac
                case "$_path" in
                    /|*..*|*//*|*' '*) DURANIUM_LAST_ERROR="unsafe state path: $_path"; return 1 ;;
                esac
                ;;
            *)
                DURANIUM_LAST_ERROR="bad state.conf line: $_line"
                return 1
                ;;
        esac
    done < "$_conf"
    return 0
}

state_init_layout() {
    local _p _root
    _root=${1:-$DURANIUM_STATE_MNT}
    dur_mkdir "$_root" || return 1
    dur_mkdir "$_root/duranium" || return 1
    dur_mkdir "$_root/duranium/backups" || return 1
    dur_mkdir "$_root/duranium/boot" || return 1
    for _p in $STATE_PERSISTENT $STATE_RECREATABLE; do
        dur_mkdir "$_root$_p" || return 1
    done
    if [ ! -r "$_root/duranium/schema" ]; then
        printf '%s\n' "$STATE_SCHEMA_DECLARED" > "$_root/duranium/schema"
        sync 2>/dev/null || true
    fi
    return 0
}

state_schema_get() {
    local _v
    if [ -r "$DURANIUM_STATE_MNT/duranium/schema" ]; then
        _v=$(tr -d '\n' < "$DURANIUM_STATE_MNT/duranium/schema")
        case "$_v" in
            ''|*[!0-9]*)
                DURANIUM_LAST_ERROR="STATE schema file is corrupt"
                return 1
                ;;
        esac
        printf '%s\n' "$_v"
        return 0
    fi
    printf '0\n'
    return 0
}

state_schema_set() {
    local _new
    _new=$1
    dur_is_uint "$_new" || return 1
    dur_mkdir "$DURANIUM_STATE_MNT/duranium" || return 1
    printf '%s\n' "$_new" > "$DURANIUM_STATE_MNT/duranium/schema.tmp.$$"
    sync 2>/dev/null || true
    mv -f "$DURANIUM_STATE_MNT/duranium/schema.tmp.$$" "$DURANIUM_STATE_MNT/duranium/schema" || return 1
    sync 2>/dev/null || true
    return 0
}

# True when the STATE tree holds no data: no declared persistent/recreatable
# path and no Duranium bookkeeping. Used to distinguish a genuinely fresh
# STATE (schema marker may be created) from a tree whose schema marker was
# lost (partial factory reset, backup restore, manual deletion).
state_tree_is_empty() {
    local _p
    [ -e "$DURANIUM_STATE_MNT" ] || return 0
    for _p in $STATE_PERSISTENT $STATE_RECREATABLE; do
        [ -e "$DURANIUM_STATE_MNT$_p" ] && return 1
    done
    for _p in bootlog backups boot migrations.log duranium.log updates.log; do
        [ -e "$DURANIUM_STATE_MNT/duranium/$_p" ] && return 1
    done
    return 0
}

state_backup() {
    local _dest _label
    _label=$1
    _dest="$DURANIUM_STATE_MNT/duranium/backups/${_label}-$(date +%s).tar"
    dur_mkdir "$DURANIUM_STATE_MNT/duranium/backups" || return 1
    if ! command -v tar >/dev/null 2>&1; then
        DURANIUM_LAST_ERROR="tar is required for state backup"
        return 1
    fi
    ( cd "$DURANIUM_STATE_MNT" && tar -cf "$_dest" --exclude='./duranium/backups' . ) || {
        DURANIUM_LAST_ERROR="state backup failed"
        return 1
    }
    sync 2>/dev/null || true
    printf '%s\n' "$_dest"
    return 0
}

state_backup_prune() {
    # Keep only the most recent backups; unbounded growth eventually fills
    # STATE, and a failed backup aborts the migration and marks the pending
    # slot BAD until an operator intervenes.
    local _dir _f _keep
    _keep=${DURANIUM_MIGRATION_BACKUP_KEEP:-3}
    dur_is_uint "$_keep" || _keep=3
    _dir="$DURANIUM_STATE_MNT/duranium/backups"
    [ -d "$_dir" ] || return 0
    for _f in $(ls -1t "$_dir"/before-*.tar 2>/dev/null | tail -n +$((_keep + 1))); do
        rm -f "$_f" 2>/dev/null || true
    done
    return 0
}

state_migration_kind() {
    local _conf _kind
    _conf=$1
    [ -r "$_conf" ] || { printf 'unknown\n'; return 0; }
    _kind=$(sed -n 's/^kind=//p' "$_conf" | head -n 1)
    [ -n "$_kind" ] || _kind=unknown
    printf '%s\n' "$_kind"
}

state_migrate() {
    local _backup _conf _current _from _kind _required _script _to
    _required=$1
    dur_is_uint "$_required" || { DURANIUM_LAST_ERROR="invalid required state schema"; return 3; }
    _current=$(state_schema_get) || {
        DURANIUM_LAST_ERROR="STATE schema is corrupt: $DURANIUM_LAST_ERROR"
        return 3
    }
    if [ "$_current" = "0" ]; then
        # Fast-forward 0 -> required only on a genuinely empty STATE tree.
        # A tree with data and no schema marker has a lost marker; claiming
        # an unmigrated layout would expose user data to the new schema.
        state_load_config 2>/dev/null || true
        if ! state_tree_is_empty; then
            DURANIUM_LAST_ERROR="STATE schema marker is missing but STATE has data; refusing to fast-forward"
            return 3
        fi
        state_schema_set "$_required" || return 1
        return 0
    fi
    if [ "$_current" -ge "$_required" ]; then
        # Newer STATE is allowed on rollback only because V1 migrations are
        # required to be additive/backward-compatible. Older slots read their
        # old paths and ignore the added layout.
        return 0
    fi
    _from=$_current
    while [ "$_from" -lt "$_required" ]; do
        _to=$((_from + 1))
        _script="$DURANIUM_MIGRATIONS_DIR/${_from}-to-${_to}.sh"
        _conf="$DURANIUM_MIGRATIONS_DIR/${_from}-to-${_to}.conf"
        [ -r "$_script" ] || {
            DURANIUM_LAST_ERROR="no migration $_from -> $_to"
            return 3
        }
        _kind=$(state_migration_kind "$_conf")
        case "$_kind" in
            backward-compatible|reversible|duplicated) ;;
            irreversible)
                if [ "${DURANIUM_TEST_ACCEPT_IRREVERSIBLE:-0}" != "1" ]; then
                    # While the previous GOOD slot is expected to remain a
                    # rollback target, irreversible state changes are unsafe.
                    DURANIUM_LAST_ERROR="irreversible migration $_from -> $_to rejected while rollback is possible"
                    return 2
                fi
                ;;
            *)
                DURANIUM_LAST_ERROR="migration $_from -> $_to has unknown kind '$_kind'"
                return 3
                ;;
        esac
        _backup=""
        if [ "${DURANIUM_MIGRATION_BACKUP:-1}" = "1" ]; then
            _backup=$(state_backup "before-${_from}-to-${_to}") || return 1
        fi
        dur_log "running state migration $_from -> $_to ($_kind)"
        if ! DURANIUM_STATE_MNT="$DURANIUM_STATE_MNT" DURANIUM_STATE_BACKUP="$_backup" sh "$_script"; then
            DURANIUM_LAST_ERROR="state migration $_from -> $_to failed"
            return 2
        fi
        state_schema_set "$_to" || return 1
        state_backup_prune || true
        printf '%s migration %s->%s ok kind=%s backup=%s\n' \
            "$(dur_timestamp)" "$_from" "$_to" "$_kind" "${_backup:-none}" \
            >> "$DURANIUM_STATE_MNT/duranium/migrations.log" 2>/dev/null || true
        _from=$_to
    done
    return 0
}

state_migrate_boot() {
    local _rc _required _slot
    _slot=$1
    state_load_config || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    state_init_layout || { dur_err "cannot initialize STATE layout"; return 1; }
    meta_load_slot "$_slot" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    _required=$MS_state_schema
    state_migrate "$_required"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        return 0
    fi
    dur_err "state migration failed for slot $_slot (rc=$_rc): ${DURANIUM_LAST_ERROR:-unknown}"
    if [ "$MS_status" = "PENDING" ]; then
        slot_mark_bad "$_slot" || true
        return 3
    fi
    return 1
}

state_prepare_mounts() {
    local _p _state
    # Called from the initramfs. NEWROOT is the chosen system root.
    NEWROOT=$1
    state_load_config || return 1
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        state_init_layout "$NEWROOT/state" || return 1
        for _p in $STATE_PERSISTENT $STATE_RECREATABLE; do
            dur_mkdir "$NEWROOT/state$_p" || return 1
            dur_mkdir "$NEWROOT$_p" || return 1
        done
        return 0
    fi
    dur_mkdir "$NEWROOT/state" || return 1
    if ! dur_is_mounted "$NEWROOT/state"; then
        mount -t ext4 -o rw "$DURANIUM_STATE_DEV" "$NEWROOT/state" 2>/dev/null || {
            DURANIUM_LAST_ERROR="cannot mount STATE at $NEWROOT/state"
            return 1
        }
    fi
    _state="$NEWROOT/state"
    if [ ! -d "$_state/duranium" ]; then
        mkdir -p "$_state/duranium/backups" "$_state/duranium/boot" 2>/dev/null || true
        printf '%s\n' "$STATE_SCHEMA_DECLARED" > "$_state/duranium/schema" 2>/dev/null || true
    fi
    for _p in $STATE_PERSISTENT $STATE_RECREATABLE; do
        dur_mkdir "$_state$_p" || return 1
        if [ ! -d "$NEWROOT$_p" ]; then
            DURANIUM_LAST_ERROR="system image is missing state mountpoint $_p"
            return 1
        fi
        mount --bind "$_state$_p" "$NEWROOT$_p" 2>/dev/null || {
            DURANIUM_LAST_ERROR="cannot bind STATE path $_p"
            return 1
        }
    done
    # /run must exist before boot.env is written. It is always ephemeral.
    dur_mkdir "$NEWROOT/run" || return 1
    mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$NEWROOT/run" 2>/dev/null || true
    for _p in $STATE_EPHEMERAL; do
        [ "$_p" = "/run" ] && continue
        if [ -d "$NEWROOT$_p" ]; then
            mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$NEWROOT$_p" 2>/dev/null || true
        fi
    done
    return 0
}

state_factory_reset_state() {
    local _mode
    _mode=$1
    case "$_mode" in
        state|full)
            backend_state_format || return 1
            STATE_SCHEMA_DECLARED=1
            state_init_layout "$DURANIUM_STATE_MNT" || return 1
            ;;
        os) return 0 ;;
        *) DURANIUM_LAST_ERROR="bad factory reset mode"; return 1 ;;
    esac
    return 0
}
