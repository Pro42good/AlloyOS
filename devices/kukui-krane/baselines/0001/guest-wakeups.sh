#!/bin/sh
# Guest-side idle wakeups measurement (busybox sh + awk only).
# Usage (remote): sh -s <idle_seconds>
IDLE="${1:-60}"

# settle into true idle first
sleep 15
cat /proc/interrupts > /tmp/i0
grep '^intr ' /proc/stat > /tmp/s0
sleep "$IDLE"
cat /proc/interrupts > /tmp/i1
grep '^intr ' /proc/stat > /tmp/s1

sum_all() {
  awk 'NR > 1 {
    n = split($0, f, /[ \t]+/); s = 0
    for (j = 2; j <= n; j++) if (f[j] ~ /^[0-9]+$/) s += f[j]
    total += s
  } END { print total }' "$1"
}

T0=$(sum_all /tmp/i0); T1=$(sum_all /tmp/i1)
S0=$(awk '{print $2}' /tmp/s0); S1=$(awk '{print $2}' /tmp/s1)

# per-IRQ deltas (top 8): pass1=i0 builds base, pass2=i1 computes delta
awk -v idle="$IDLE" '
NR == FNR {
  n = split($0, f, /[ \t]+/); s = 0
  for (j = 2; j <= n; j++) if (f[j] ~ /^[0-9]+$/) s += f[j]
  base[FNR] = s
  next
}
{
  n = split($0, f, /[ \t]+/); s = 0
  for (j = 2; j <= n; j++) if (f[j] ~ /^[0-9]+$/) s += f[j]
  d = s - base[FNR]
  if (d > 0) {
    desc = ""
    for (j = 3; j <= n; j++) if (f[j] !~ /^[0-9]+$/) desc = desc " " f[j]
    printf "%8d %7.2f/s  %s\n", d, d/idle, substr(desc, 1, 70)
  }
}
' /tmp/i0 /tmp/i1 | sort -rn | head -8

echo "window=${IDLE}s"
echo "irq_delta=$((T1 - T0)) rate=$(awk -v d=$((T1-T0)) -v i="$IDLE" 'BEGIN{printf "%.2f", d/i}')/s"
echo "proc_stat_intr_delta=$((S1 - S0)) rate=$(awk -v d=$((S1-S0)) -v i="$IDLE" 'BEGIN{printf "%.2f", d/i}')/s"
rm -f /tmp/i0 /tmp/i1 /tmp/s0 /tmp/s1
