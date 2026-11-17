#!/bin/sh
# Collect ALLOY metrics from a running VM via SSH (key auth, root@127.0.0.1:2222).
# Usage: collect-metrics.sh <prefix> [idle_seconds]
# Writes ./out/<prefix>.*.txt
set -eu
PREFIX="$1"; IDLE="${2:-60}"
# SECURITY_AUDIT2 MED-4: no path traversal through the prefix
printf '%s' "$PREFIX" | grep -qE '^[A-Za-z0-9._-]+$' || { echo "bad prefix (need [A-Za-z0-9._-]+)"; exit 2; }
DIR="$(cd "$(dirname "$0")" && pwd)"
KH="$(cd "$(dirname "$0")/../.." && pwd)/alloy/known_hosts"
OUT="$DIR/out"; mkdir -p "$OUT"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -p 2222 root@127.0.0.1"

# 0. system context
$SSH 'uname -a; head -3 /etc/os-release; uptime' > "$OUT/$PREFIX.system.txt" 2>&1

# 1. boot RAM (settled ~20s after boot)
$SSH 'free -m; echo ---; grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Slab):" /proc/meminfo; echo ---; dmesg | grep -iE "memory:|Memory available|Freeing unused"' > "$OUT/$PREFIX.ram.txt" 2>&1

# 2. processes: count + top RSS (busybox-safe, via /proc) + running services + failures
$SSH 'echo "count: $(ls -d /proc/[0-9]* | wc -l)"; for p in /proc/[0-9]*; do c=$(cat "$p/comm" 2>/dev/null) || continue; r=$(awk "{print \$2*4}" "$p/statm" 2>/dev/null) || continue; echo "$r $c"; done | sort -rn | head -20; echo ---; systemctl list-units --type=service --state=running --no-pager --no-legend; echo ---; systemctl --failed --no-pager --no-legend' > "$OUT/$PREFIX.processes.txt" 2>&1

# 3. boot time breakdown (inside guest)
$SSH 'systemd-analyze; echo ---; systemd-analyze blame | head -20; echo ---; systemd-analyze critical-chain 2>/dev/null | head -15' > "$OUT/$PREFIX.systemd-analyze.txt" 2>&1

# 4. idle wakeups (guest-side busybox script)
sleep 5
$SSH "sh -s $IDLE" < "$DIR/guest-wakeups.sh" > "$OUT/$PREFIX.wakeups.txt" 2>&1

# 5. storage footprint
$SSH 'df -h /; echo ---; du -sxm /usr /lib /var /etc /opt 2>/dev/null | sort -rn | head; echo ---; du -xm /usr/* 2>/dev/null | sort -rn | head -12' > "$OUT/$PREFIX.disk.txt" 2>&1

echo "collected -> $OUT/$PREFIX.*"
