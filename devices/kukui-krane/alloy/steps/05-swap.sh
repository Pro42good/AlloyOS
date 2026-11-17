#!/bin/sh
# ALLOY stage 05 — swap layering: zram (pmOS, pri 300) + 2 GB disk overflow.
# SECURITY_AUDIT MED-2: dd-zero the swapfile instead of bare fallocate so no
# stale disk contents can ever surface through swap. (Also makes the region
# compress cleanly in qcow2 flattens.)
set -e
dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
chmod 600 /swapfile
mkswap /swapfile 2>&1 | tail -1
grep -q swapfile /etc/fstab || echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
swapon /swapfile || true
swapon --show
