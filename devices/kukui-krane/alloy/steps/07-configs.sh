#!/bin/sh
# ALLOY stage 07 — configuration sweep + final trim (SSH dev tunnels, listener
# surface, journal both-tier caps, PID1, udevd, noatime, bluetooth off).
set -e
printf "AllowTcpForwarding no\nLoginGraceTime 30\nClientAliveInterval 60\nClientAliveCountMax 3\n" \
    > /etc/ssh/sshd_config.d/00-alloy.conf
mkdir -p /etc/NetworkManager/conf.d
printf "[connectivity]\nenabled=false\n\n[logging]\nlevel=WARN\n" > /etc/NetworkManager/conf.d/00-alloy.conf
mkdir -p /etc/systemd/resolved.conf.d
printf "[Resolve]\nLLMNR=no\n" > /etc/systemd/resolved.conf.d/00-alloy.conf
printf "[Journal]\nSystemMaxUse=10M\nRuntimeMaxUse=10M\n" > /etc/systemd/journald.conf.d/10-alloy-cap.conf
mkdir -p /etc/systemd/system.conf.d
printf "[Manager]\nDefaultTimeoutStopSec=5s\n" > /etc/systemd/system.conf.d/00-alloy.conf
mkdir -p /etc/udev
if [ -f /etc/udev/udev.conf ]; then
  sed -i "s/^#children_max=.*/children_max=2/; s/^children_max=.*/children_max=2/" /etc/udev/udev.conf
  grep -q "^children_max" /etc/udev/udev.conf || echo "children_max=2" >> /etc/udev/udev.conf
else
  printf "# ALLOY: bounded coldplug parallelism\nchildren_max=2\n" > /etc/udev/udev.conf
fi
sed -i "s/rw,relatime/noatime/g" /etc/fstab
systemctl disable bluetooth.service 2>&1 | tail -1 || true
systemctl restart NetworkManager systemd-resolved systemd-udevd sshd || true
journalctl --vacuum-size=5M 2>&1 | tail -1
fstrim -v /
fstrim -v /boot
systemctl --failed --no-legend | wc -l
printf "KEYMAP=us\n" > /etc/vconsole.conf
