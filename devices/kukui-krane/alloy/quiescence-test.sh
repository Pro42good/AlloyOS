#!/bin/sh
# ALLOY quiescence gate — formal idle-behavior test. Boots the image on a
# throwaway overlay (frozen files allowed), settles, measures, asserts
# thresholds, powers off. Exit 0 only if all gates pass.
# Usage: quiescence-test.sh <img.qcow2> [profile]   (profile: core|prod|dev|lab)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KH="$(cd "$(dirname "$0")" && pwd)/known_hosts"
IMG="$1"; PROFILE="${2:-core}"
W="$(mktemp -d "${TMPDIR:-/tmp}/alloy-qui.XXXXXXXX")" || exit 2
VARS_SEED="${VARS:-$REPO/baselines/0007/vars.fd}"
if [ -f "$VARS_SEED" ]; then
  cp "$VARS_SEED" "$W/vars.fd" || { rm -rf "$W"; exit 2; }
fi
PORT=2222
FAIL=0

case "$PROFILE" in
  core|prod) SVC_MODE=exact; SVC=12;  PROC=115; RAM=140; IRQ=12; CPU_PCT=1; WRT_MB=2 ;;
  dev)       SVC_MODE=max;   SVC=16;  PROC=150; RAM=500; IRQ=15; CPU_PCT=1; WRT_MB=2 ;;
  lab)       SVC_MODE=max;   SVC=16;  PROC=150; RAM=350; IRQ=15; CPU_PCT=1; WRT_MB=2 ;;
  core-nura) SVC_MODE=max;   SVC=14;  PROC=120; RAM=140; IRQ=12; CPU_PCT=1; WRT_MB=2 ;;
  *) echo "unknown profile: $PROFILE"; exit 2 ;;
esac

echo "== quiescence ($PROFILE): $IMG"
T0="$(python3 -c 'import time;print(time.time())')"
if ! qemu-img create -f qcow2 -F qcow2 -b "$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")" "$W/ov.qcow2" >/dev/null ||
   ! "$REPO/scripts/run-qemu-headless.sh" "$W/ov.qcow2" "$W/serial.log" "$W/qemu.pid" "$PORT" "$W/vars.fd"; then
  rm -rf "$W"
  exit 2
fi
UP=0; i=0
while [ $i -lt 240 ]; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -p "$PORT" root@127.0.0.1 true 2>/dev/null && { UP=1; break; }
  sleep 2; i=$((i+2))
done
if [ "$UP" = 1 ]; then :; else echo "  FAIL  image never booted"; kill "$(cat "$W/qemu.pid" 2>/dev/null)" 2>/dev/null; true; rm -rf "$W"; exit 2; fi
T1="$(python3 -c 'import time;print(time.time())')"
BOOT="$(python3 -c "print(f'{$T1-$T0:.1f}')" | tr -cd "0-9.")"
if python3 -c "import sys; sys.exit(0 if $BOOT <= 35 else 1)"; then
  echo "  PASS  boot->ssh ${BOOT}s (<=35)"
else echo "  FAIL  boot->ssh ${BOOT}s"; FAIL=1; fi

sleep 120   # settle: journald flush, dhcp, first-boot residue

SSHCM="-o ControlMaster=auto -o ControlPath=$W/cm -o ControlPersist=300"
G() { ssh $SSHCM -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
        -p "$PORT" root@127.0.0.1 "$1" 2>/dev/null | grep -v '^Warning'; }

SVCN="$(G 'systemctl list-units --type=service --state=running --no-legend | wc -l | tr -d " "')"
if [ "$SVC_MODE" = exact ]; then
  [ "$SVCN" = "$SVC" ] && echo "  PASS  services = $SVCN (== $SVC)" || { echo "  FAIL  services = $SVCN (want $SVC)"; FAIL=1; }
else
  [ "$SVCN" -le "$SVC" ] && echo "  PASS  services = $SVCN (<= $SVC)" || { echo "  FAIL  services = $SVCN"; FAIL=1; }
fi

PR="$(G 'ls -d /proc/[0-9]* | wc -l | tr -d " "')"
[ "$PR" -le "$PROC" ] && echo "  PASS  processes = $PR (<= $PROC)" || { echo "  FAIL  processes = $PR"; FAIL=1; }

RM="$(G 'free -m | sed -n 2p | awk "{print \$3}"' | tr -cd "0-9.")"
if python3 -c "import sys; sys.exit(0 if $RM <= $RAM else 1)"; then
  echo "  PASS  boot RAM ${RM} MiB (<= $RAM)"
else echo "  FAIL  boot RAM ${RM} MiB"; FAIL=1; fi

[ "$(G 'systemctl --failed --no-legend | wc -l | tr -d " "')" = 0 ] \
  && echo "  PASS  failed units = 0" || { echo "  FAIL  failed units"; FAIL=1; }

# one 60s window: IRQs + CPU busy + writes (guest-side minimal sampler)
G 'cat /proc/interrupts > /tmp/q.i; grep "^cpu " /proc/stat > /tmp/q.c; grep "^pgpgout" /proc/vmstat > /tmp/q.v; sleep 60; cat /proc/interrupts > /tmp/q.i1; grep "^cpu " /proc/stat > /tmp/q.c1; grep "^pgpgout" /proc/vmstat > /tmp/q.v1' >/dev/null

IRQ0="$(G 'awk "NR>1{for(j=2;j<=NF;j++) if (\$j ~ /^[0-9]+\$/) s+=\$j} END{print s}" /tmp/q.i')"
IRQ1="$(G 'awk "NR>1{for(j=2;j<=NF;j++) if (\$j ~ /^[0-9]+\$/) s+=\$j} END{print s}" /tmp/q.i1')"
IRQ_RATE="$(python3 -c "print(f'{($IRQ1-$IRQ0)/60:.2f}')" | tr -cd "0-9.")"
if python3 -c "import sys; sys.exit(0 if $IRQ_RATE <= $IRQ else 1)"; then
  echo "  PASS  idle IRQ ${IRQ_RATE}/s (<= $IRQ)"
else echo "  FAIL  idle IRQ ${IRQ_RATE}/s"; FAIL=1; fi

CPU_RAW="$(G 'cat /tmp/q.c; echo ---; cat /tmp/q.c1')"
BUSY_PCT="$(python3 - "$CPU_RAW" <<'PYEOF'
import sys
parts = sys.argv[1].split("---")
rows = [l.split()[1:] for p in parts for l in p.splitlines() if l.startswith("cpu ")]
if len(rows) < 2: print(999); raise SystemExit
a = [int(x) for x in rows[0]]; b = [int(x) for x in rows[1]]
busy = (sum(b) - sum(a)) - (b[3] - a[3]) - (b[4] - a[4])
print(f"{100.0*max(busy,0)/max(sum(b)-sum(a),1):.2f}")
PYEOF
)"
if python3 -c "import sys; sys.exit(0 if float('$BUSY_PCT') <= $CPU_PCT else 1)"; then
  echo "  PASS  idle CPU ${BUSY_PCT}% (<= ${CPU_PCT}%)"
else echo "  FAIL  idle CPU ${BUSY_PCT}%"; FAIL=1; fi

V0="$(G 'cat /tmp/q.v | awk "{print \$2}"')"
V1="$(G 'cat /tmp/q.v1 | awk "{print \$2}"')"
WR_MB="$(python3 -c "print(f'{($V1-$V0)*4096/1048576:.1f}')" | tr -cd "0-9.")"
if python3 -c "import sys; sys.exit(0 if float('$WR_MB') <= $WRT_MB else 1)"; then
  echo "  PASS  idle writes ${WR_MB} MB/60s (<= $WRT_MB)"
else echo "  FAIL  idle writes ${WR_MB} MB"; FAIL=1; fi

NS="$(G 'netstat -tln 2>/dev/null')"
LL="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 ~ /:5355$/' | wc -l | tr -d ' ')"
CNT="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 ~ /:/' | wc -l | tr -d ' ')"
BAD="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 !~ /:(22|53)$/' | wc -l | tr -d ' ')"
if [ "$LL" = 0 ] && [ "$CNT" = 4 ] && [ "$BAD" = 0 ]; then
  echo "  PASS  listeners = 4 (:22 v4+v6, :53 x2, no LLMNR)"
else echo "  FAIL  listeners ($CNT total, $LL llmnr, $BAD unexpected)"; FAIL=1; fi

G 'rm -f /tmp/q.*' >/dev/null
ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
    -p "$PORT" root@127.0.0.1 'poweroff' 2>/dev/null || true
sleep 8
rm -rf "$W"
if [ "$FAIL" = 0 ]; then echo "QUIESCENCE: ALL PASS"; else echo "QUIESCENCE: GATES FAILED"; exit 1; fi
