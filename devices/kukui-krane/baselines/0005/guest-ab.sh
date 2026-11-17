#!/bin/sh
# A/B: 60s sample -> apply watchdog=0 + stat_interval=100 -> 60s sample.
sumline() { # sum numeric fields of the arch_timer + IPI lines
  awk 'NR>1 && /arch_timer/ { for (j=2;j<=NF;j++) if ($j ~ /^[0-9]+$/) t+=$j; print "timer", t; t=0 }
       NR>1 && /Function call/ { for (j=2;j<=NF;j++) if ($j ~ /^[0-9]+$/) f+=$j; print "ipi", f; f=0 }
       NR>1 && /Rescheduling/ { for (j=2;j<=NF;j++) if ($j ~ /^[0-9]+$/) r+=$j; print "resched", r; r=0 }' "$1"
}
snap() {
  sumline /proc/interrupts
  grep '^intr ' /proc/stat | awk '{print "total", $2}'
  cp /proc/vmstat /tmp/vm.$1
}
echo "== A (0004 knobs): 60s"
snap a0
sleep 60
snap a1
{
  sumline /proc/interrupts >/dev/null  # warm
  awk 'NR==FNR{a[$1]=$2;next}{d=$2-a[$1]; if (d) print $1, d}' /tmp/vm.a0 /tmp/vm.a1 | grep -E "pgpgout|pgfault" | head -3
}
# apply live
sysctl -w kernel.watchdog=0 vm.stat_interval=100 >/dev/null
echo "== applied: $(sysctl -n kernel.watchdog) $(sysctl -n vm.stat_interval); 60s"
sleep 5
snap b0
sleep 60
snap b1
echo "== deltas (A then B), per 60s window:"
awk 'NR==FNR{a[$1]=$2;next}{d=$2-a[$1]; if (d) print $1, d}' /tmp/vm.a0 /tmp/vm.a1 | grep -E "pgpgout|pgfault"
awk 'NR==FNR{a[$1]=$2;next}{d=$2-a[$1]; if (d) print $1, d}' /tmp/vm.b0 /tmp/vm.b1 | grep -E "pgpgout|pgfault"
rm -f /tmp/vm.a0 /tmp/vm.a1 /tmp/vm.b0 /tmp/vm.b1
