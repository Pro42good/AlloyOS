#!/bin/sh
# Offload demo v3: cross the watermark (4.0GB tmpfs on 3.9GB RAM).
sec() { echo; echo "== $1 =="; }
state() {
  free -m | sed -n '2p;3p'
  awk '{printf "zram: orig=%.0fMB compr=%.0fMB mem=%.0fMB\n", $1/1048576, $2/1048576, $3/1048576}' /sys/block/zram0/mm_stat
  swapon --show 2>/dev/null | tail -2
}
lat() { echo "-- resp: $( { time -p sh -c "apk search -q e2fsprogs >/dev/null 2>&1"; } 2>&1 | grep real )"; }

# protect sshd from OOM during the demo (runtime-only)
for p in /proc/[0-9]*; do
  if grep -qs sshd "$p/comm" 2>/dev/null; then echo -800 > "$p/oom_score_adj" 2>/dev/null; fi
done

sec "T0: fresh 4200m tmpfs"
mount -t tmpfs -o size=4200m demo /mnt; state

sec "T1: 3.0GB zeros"
dd if=/dev/zero of=/mnt/z1 bs=1M count=3000 status=none; state; lat

sec "T2: 3.6GB zeros — crossing supply"
dd if=/dev/zero of=/mnt/z2 bs=1M count=600 status=none; state; lat

sec "T3: +0.4GB urandom (4.0GB total) — reclaim must swap"
dd if=/dev/urandom of=/mnt/r1 bs=1M count=400 status=none; sync; state; lat
echo "-- apk: $(apk update 2>&1 | tail -1)"
echo "-- oom events: $(dmesg | grep -c -i 'out of memory')"
grep -E "pswpout|pgscan_kswapd" /proc/vmstat

sec "T4: cleanup + drain"
umount /mnt; sync; sleep 2; state
swapoff -a && swapon -a 2>/dev/null; echo "-- swap drained:"; free -m | sed -n '2p;3p'
