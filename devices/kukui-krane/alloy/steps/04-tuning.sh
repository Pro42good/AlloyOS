#!/bin/sh
# ALLOY stage 04 — runtime tuning: sysctls, boot cmdline, enablement diet.
set -e
printf "vm.stat_interval = 10\nvm.dirty_writeback_centisecs = 6000\nvm.compaction_proactiveness = 0\nvm.watermark_boost_factor = 0\n" \
    > /etc/sysctl.d/10-alloy-idle.conf
sed -i "s/^options .*/options console=tty1 console=ttyAMA0,115200 transparent_hugepage=madvise psi=0/" \
    /boot/loader/entries/pmos.conf
grep options /boot/loader/entries/pmos.conf
systemctl disable wpa_supplicant.service rtkit-daemon.service 2>&1 | tail -1
