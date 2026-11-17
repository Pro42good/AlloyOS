#!/bin/sh
# Health checks consulted by "duranium mark-good".
#
# The fixture supplies /run/alloy/core-ready. Real Alloy Core can use
# systemd checks via contrib/alloy-core/health-core.sh. A pending slot cannot
# become GOOD unless these checks pass.

health_root_is_ro() {
    local _opts
    [ "${DURANIUM_HEALTH_REQUIRE_ROOT_RO:-1}" = "1" ] || return 0
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        return 0
    fi
    _opts=$(dur_mount_opts /)
    case ",$_opts," in
        *,ro,*) return 0 ;;
    esac
    dur_err "health: / is not mounted read-only"
    return 1
}

health_state_mounted() {
    [ "${DURANIUM_HEALTH_REQUIRE_STATE:-1}" = "1" ] || return 0
    if [ "$DURANIUM_BACKEND" = "dir" ]; then
        [ -d "$DURANIUM_STATE_MNT" ]
        return $?
    fi
    if dur_is_mounted "$DURANIUM_STATE_MNT"; then
        return 0
    fi
    dur_err "health: STATE is not mounted at $DURANIUM_STATE_MNT"
    return 1
}

health_core_ready() {
    local _failed _state
    [ "${DURANIUM_HEALTH_REQUIRE_CORE:-1}" = "1" ] || return 0
    if [ "${DURANIUM_TEST_HEALTH_FAIL:-0}" = "1" ] && [ "$DURANIUM_TEST_MODE" = "1" ]; then
        dur_err "health: injected core failure"
        return 1
    fi
    if [ -e "${DURANIUM_HEALTH_CORE_MARKER:-/run/alloy/core-ready}" ]; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        _state=$(systemctl is-system-running 2>/dev/null || true)
        case "$_state" in
            running|starting)
                # "starting" is accepted only when no failed units are present;
                # mark-good normally runs late enough to see "running".
                _failed=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')
                if [ "${_failed:-0}" -gt 0 ]; then
                    dur_err "health: systemd reports $_failed failed units"
                    return 1
                fi
                return 0
                ;;
            *)
                dur_err "health: systemd is not healthy ($_state)"
                return 1
                ;;
        esac
    fi
    dur_err "health: no core-readiness signal"
    return 1
}

health_expected_services() {
    local _file _svc
    _file=/etc/duranium/core-services
    [ -r "$_file" ] || return 0
    if command -v systemctl >/dev/null 2>&1; then
        while IFS= read -r _svc; do
            case "$_svc" in ''|\#*) continue ;; esac
            if ! systemctl is-active --quiet "$_svc" 2>/dev/null; then
                dur_err "health: expected service is not active: $_svc"
                return 1
            fi
        done < "$_file"
    else
        while IFS= read -r _svc; do
            case "$_svc" in ''|\#*) continue ;; esac
            [ -e "/run/alloy/service-$_svc" ] || {
                dur_err "health: expected core service marker missing: $_svc"
                return 1
            }
        done < "$_file"
    fi
    return 0
}

health_check() {
    local _dir _ok _script
    _ok=0
    health_root_is_ro || _ok=1
    health_state_mounted || _ok=1
    health_core_ready || _ok=1
    health_expected_services || _ok=1

    _dir=/etc/duranium/health.d
    if [ -d "$_dir" ]; then
        for _script in "$_dir"/*.sh; do
            [ -r "$_script" ] || continue
            if ! sh "$_script"; then
                dur_err "health: $_script failed"
                _ok=1
            fi
        done
    fi
    return "$_ok"
}

health_report() {
    printf 'root read-only: '
    if health_root_is_ro >/dev/null 2>&1; then printf 'ok\n'; else printf 'FAILED\n'; fi
    printf 'state mounted:  '
    if health_state_mounted >/dev/null 2>&1; then printf 'ok\n'; else printf 'FAILED\n'; fi
    printf 'core ready:     '
    if health_core_ready >/dev/null 2>&1; then printf 'ok\n'; else printf 'FAILED\n'; fi
    printf 'expected svcs:  '
    if health_expected_services >/dev/null 2>&1; then printf 'ok\n'; else printf 'FAILED\n'; fi
}
