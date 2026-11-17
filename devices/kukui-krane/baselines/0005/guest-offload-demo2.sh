#!/bin/sh
# Offload demo v2: create REAL memory pressure (3.5GB tmpfs on 4GB VM).
sec() { echo; echo "== $1 =="; }
state() {
  free -m | sed -n '2p;3p'
  swapon --show 2>/dev/null
  awk '{printf "zram: orig=%.0fMB compr=%.0fMB mem=%.0fMB ratio=%.2f\n", $1/1048576, $2/1048576, $3/1048576, $1/$2}' /sys/block/zram0/mm_stat
}
lat() { echo "-- resp: $( { time -p sh -c "apk search -q e2fsprogs >/dev/null 2>&1"; } 2>&1 | grep real )"; }

sec "T0 baseline"
mount -t tmpfs -o size=3700m demo /mnt
state

sec "T1 +500MB zeros"
dd if=/dev/zero of=/mnt/z1 bs=1M count=500 status=none; state; lat

sec "T2 +1.3GB zeros (1.8G total)"
dd if=/dev/zero of=/mnt/z2 bs=1M count=1300 status=none; state; lat

sec "T3 +1.7GB urandom (3.5G total)"
dd if=/dev/urandom of=/mnt/r1 bs=1M count=1700 status=none; sync; state; lat
echo "-- apk: $(apk update 2>&1 | tail -1)"
echo "-- dns: $(nslookup dl-cdn.alpinelinux.org 2>/dev/null | grep -c Address)"

sec "T4 cleanup"
umount /mnt; sync; sleep 2; state
swapoff /swapfile && swapon /swapfile; echo "-- swap drained"
free -m | sed -n '2p;3p'
rm -f /swapfile.swp
