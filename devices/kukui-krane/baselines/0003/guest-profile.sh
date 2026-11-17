#!/bin/sh
# Runtime profile of ALLOY-BASELINE-0003: per-process CPU / wakeups / IO over 60s.
CLK=100
snap() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    c=$(cat "$p/comm" 2>/dev/null) || continue
    awk -v pid="$pid" -v c="$c" '{ printf "%s %s %d %d\n", pid, c, $14, $15 }' "$p/stat" 2>/dev/null
    awk -v pid="$pid" '/voluntary_ctxt/{v=$2} /nonvoluntary/{n=$2} END{if (v!="") printf "%s V %d %d\n", pid, v, n}' "$p/status" 2>/dev/null
    awk -v pid="$pid" '/^write_bytes/{if (NR>0) printf "%s W %d\n", pid, $2}' "$p/io" 2>/dev/null
  done
}
sec() { echo; echo "===== $1 ====="; }

echo "PID CLOCK_TCK: $(getconf CLK_TCK 2>/dev/null || echo 100)"
cat /proc/vmstat > /tmp/vm0
cat /proc/interrupts > /tmp/i0
grep '^intr ' /proc/stat > /tmp/s0
grep '^cpu ' /proc/stat > /tmp/c0
snap > /tmp/p0
sleep 60
snap > /tmp/p1
cat /proc/vmstat > /tmp/vm1
cat /proc/interrupts > /tmp/i1
grep '^intr ' /proc/stat > /tmp/s1
grep '^cpu ' /proc/stat > /tmp/c1

sec "per-process CPU + wakeups + writes over 60s"
awk 'NR==FNR { cpu0[$1]=$3+$4; v0[$1]=$3; nv0[$1]=$4; w0[$1]=$3; next }
     $3=="V" { next }  # handled below
     { cpu1[$1]=$3+$4; name[$1]=$2 }
     END {
       print "pid  comm  cpu_s  vcs_delta  write_KB"
     }' /tmp/p0 /dev/null >/dev/null
awk '
  function addline(s) { lines[++n] = s }
  FNR == NR {
    if ($3 == "V") { v0[$1] = $3+1; vv0[$1] = $4; nv0[$1] = $5; next }
    if ($3 == "W") { w0[$1] = $4; next }
    cpu0[$1] = $3 + $4; name[$1] = $2
    next
  }
  {
    if ($3 == "V") { vv1[$1] = $4; nv1[$1] = $5; next }
    if ($3 == "W") { w1[$1] = $4; next }
    cpu1[$1] = $3 + $4
  }
  END {
    for (pid in cpu1) {
      if (pid in cpu0) {
        dcpu = (cpu1[pid] - cpu0[pid]) / 100
        dv = vv1[pid] - vv0[pid]
        dn = nv1[pid] - nv0[pid]
        dw = (w1[pid] - w0[pid]) / 1024
        if (dcpu > 0.001 || dv > 0 || dn > 0 || dw > 0)
          printf "%6s %-18s cpu=%6.3fs  vcs=%5d  nonv=%4d  write=%8.0fKB\n", pid, name[pid], dcpu, dv, dn, dw
      }
    }
  }
' /tmp/p0 /tmp/p1 | sort -t= -k2 -rn | sort -k3 -rn | head -30

sec "totals over 60s"
S0=$(awk '{print $2}' /tmp/s0); S1=$(awk '{print $2}' /tmp/s1)
echo "total irq delta: $((S1-S0)) = $(awk -v d=$((S1-S0)) 'BEGIN{printf "%.2f", d/60}')/s"
for c in 0 1 2 3; do
  a0=$(awk -v c=$c '{print $(2+c)}' /tmp/c0); a1=$(awk -v c=$c '{print $(2+c)}' /tmp/c1)
  echo "cpu$c jiffies delta: $((a1-a0)) ($(awk -v d=$((a1-a0)) 'BEGIN{printf "%.1f", d/60/100}')%)"
done
awk 'NR==FNR{a[$1]=$2;next} {d=$2-a[$1]; if (d>0) print $1, d}' /tmp/vm0 /tmp/vm1 | grep -E "^(pgpgin|pgpgout|pswpin|pswpout|pgfault|pgmajfault|nr_dirty|nr_writeback|nr_slab_reclaimable)" | head -12

sec "timers"
systemctl list-timers --all --no-pager --no-legend 2>/dev/null | awk '{print $NF, "next:", $2}'

sec "listening sockets"
netstat -tlnp 2>/dev/null | tail -n +3 | awk '{print $4, $6}' | sort -u | head -12

sec "enablement + activation files"
for u in wpa_supplicant rtkit-daemon apk-inhibit NetworkManager sshd; do printf "%-18s %s\n" "$u.service" "$(systemctl is-enabled $u.service 2>&1)"; done
ls /usr/share/dbus-1/system-services/ 2>/dev/null
grep -l "wpa_supplicant" /usr/share/dbus-1/system-services/* 2>/dev/null || echo "(no wpa dbus activation file)"

sec "user@0 lingering"
loginctl show-user root 2>/dev/null | grep -E "Linger|State" || true

sec "relevant sysctls (current)"
sysctl vm.dirty_writeback_centisecs vm.dirty_expire_centisecs vm.stat_interval kernel.sched_autogroup_enabled vm.swappiness 2>/dev/null

sec "systemd manager defaults"
systemctl show --property=DefaultTimeoutStopSec,DefaultCPUAccounting,DefaultMemoryAccounting 2>/dev/null

sec "journald effective config"
journalctl --disk-usage 2>/dev/null | tail -1
ls /etc/systemd/journald.conf.d/ 2>/dev/null
rm -f /tmp/p0 /tmp/p1 /tmp/vm0 /tmp/vm1 /tmp/i0 /tmp/i1 /tmp/s0 /tmp/s1 /tmp/c0 /tmp/c1
