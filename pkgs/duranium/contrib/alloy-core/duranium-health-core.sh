#!/bin/sh
# Alloy Core health checks for duranium mark-good.
#
# Install this as /etc/duranium/health.d/20-core-systemd.sh in a real Core
# image. The fixture uses a simpler marker-based check.
set -u

if ! command -v systemctl >/dev/null 2>&1; then
    printf 'duranium health: systemctl unavailable\n' >&2
    exit 1
fi

_state=$(systemctl is-system-running 2>/dev/null || true)
case "$_state" in
    running|starting) ;;
    *)
        printf 'duranium health: systemd state is %s\n' "${_state:-unknown}" >&2
        exit 1
        ;;
esac

_failed=$(systemctl --failed --no-legend --plain 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
if [ "${_failed:-0}" -gt 0 ]; then
    printf 'duranium health: %s failed systemd units\n' "$_failed" >&2
    exit 1
fi

# Adjust this list to the services that must be alive before a pending slot can
# be confirmed. Keep it small and explicit.
for _svc in systemd-journald.service dbus.service NetworkManager.service sshd.service; do
    if systemctl list-unit-files "$_svc" >/dev/null 2>&1; then
        if ! systemctl is-active --quiet "$_svc" 2>/dev/null; then
            printf 'duranium health: %s is not active\n' "$_svc" >&2
            exit 1
        fi
    fi
done

exit 0
