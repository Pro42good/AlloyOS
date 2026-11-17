#!/bin/sh
# Offload demo: push 2.4GB tmpfs through zram(zstd)/swapfile layering.
sec() { echo; echo "== $1 =="; }
state() {
  echo "-- free:"; free -m | head -2 | tail -1
  echo "-- swap:"; swapon --show 2>/dev/null
  echo "-- zram mm_stat (orig compr mem_used):"; awk '{printf "  orig=%.0fMB compr=%.0fMB mem=%.0fMB ratio=%.2f\n", $1/1048576, $2/1048576, $3/1048576, $1/$2}' /sys/block/zram0/mm_stat
}
lat() { # ssh-side latency probe done by host; here: local responsiveness
  echo "-- local resp: $( { time -p sh -c "apk search -q e2fsprogs >/dev/null 2>&1" ; } 2>&1 | grep real )"
}

sec "T0 baseline"
state

sec "T1 fill tmpfs 1.4GB (700M urandom + 700M zeros)"
mount -t tmpfs -o size=1600m demo /mnt
dd if=/dev/urandom of=/mnt/rnd bs=1M count=700 status=none
dd if=/dev/zero of=/mnt/zer bs=1M count=700 status=none
sync
state
lat

sec "T2 push to 2.4GB (+1GB urandom)"
dd if=/dev/urandom of=/mnt/rnd2 bs=1M count=1000 status=none
sync
state
lat
echo "-- apk works: $(apk update 2>&1 | tail -1)"
echo "-- dns: $(nslookup dl-cdn.alpinelinux.org 2>/dev/null | grep -c Address)"

sec "T3 cleanup"
umount /mnt
sync
state
