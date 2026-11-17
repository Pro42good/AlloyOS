#!/bin/sh
# ALLOY stage 02 — file/config cuts (boot files, var garbage, journal, masks).
set -e
rm -rf /boot/dtbs /boot/System.map
rm -rf /var/lib/swcatalog /var/lib/greetd /var/lib/geoclue /var/lib/plymouth \
       /var/lib/flatpak /var/lib/udhcpd /var/lib/xfsprogs
userdel greetd 2>/dev/null || true; userdel geoclue 2>/dev/null || true
userdel avahi 2>/dev/null || true; userdel pulse 2>/dev/null || true
apk cache clean 2>/dev/null || true
rm -rf /var/cache/apk/* /var/cache/distfiles /var/cache/misc /var/cache/swcatalog
rm -rf /var/cache/fontconfig/* /var/cache/private/* 2>/dev/null || true
mkdir -p /etc/systemd/journald.conf.d
printf "[Journal]\nSystemMaxUse=10M\n" > /etc/systemd/journald.conf.d/10-alloy-cap.conf
journalctl --vacuum-size=10M 2>&1 | tail -1
systemctl mask systemd-oomd.service systemd-oomd.socket \
    systemd-coredump.socket systemd-coredumpd.service \
    systemd-coredump-register.service 2>&1 | tail -1
systemctl stop systemd-oomd.service systemd-oomd.socket \
    systemd-coredump.socket systemd-coredumpd.service 2>/dev/null || true
rm -rf /etc/tuned /var/log/tuned
df -h / | tail -1
