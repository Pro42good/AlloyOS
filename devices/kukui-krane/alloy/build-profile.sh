#!/bin/sh
# ALLOY profile builder: frozen CORE -> profile artifact, gated.
# Usage: build-profile.sh <dev|prod|lab> [out.qcow2]
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KH="$(cd "$(dirname "$0")" && pwd)/known_hosts"
NAME="$1"
# SECURITY_AUDIT2 MED-3: allowlist, no path traversal into arbitrary script exec
case "$NAME" in dev|prod|lab) ;; *) echo "unknown profile: $NAME (dev|prod|lab)"; exit 2 ;; esac
OUT="${2:-$REPO/alloy/profiles/alloy-$NAME-0001.qcow2}"
CORE="$REPO/baselines/0007/alloy-baseline-0007.qcow2"
W="$REPO/alloy/build"; LOGS="$W/logs"; mkdir -p "$LOGS" "$(dirname "$OUT")"
PORT=2222
[ -f "$REPO/alloy/profiles/$NAME.sh" ] || { echo "no such profile: $NAME"; exit 2; }

OV="$W/profile-$NAME.qcow2"
rm -f "$OV" "$W/serial.log" "$W/qemu.pid"
qemu-img create -f qcow2 -F qcow2 -b "$CORE" "$OV" >/dev/null
echo "== profile $NAME: overlay on frozen CORE"
"$REPO/scripts/run-qemu-headless.sh" "$OV" "$W/serial.log" "$W/qemu.pid" "$PORT" \
    "$REPO/baselines/0007/vars.fd"
UP=0; i=0
while [ $i -lt 120 ]; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -p "$PORT" root@127.0.0.1 true 2>/dev/null && { UP=1; break; }
  sleep 2; i=$((i+2))
done
[ "$UP" = 1 ] || { echo "SSH never came up"; exit 2; }
sleep 15

ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
    -p "$PORT" root@127.0.0.1 'sh -s' < "$REPO/alloy/profiles/$NAME.sh" \
    2>&1 | grep -v '^Warning' | tee "$LOGS/profile-$NAME.log"

if [ "$NAME" = lab ]; then
  scp -q -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -P "$PORT" "$REPO"/baselines/0001/collect-metrics.sh "$REPO"/baselines/0001/guest-wakeups.sh \
      "$REPO"/baselines/0001/measure-boot.sh "$REPO"/baselines/0003/guest-profile2.sh \
      "$REPO"/alloy/steps/*.sh root@127.0.0.1:/opt/alloy/
fi

ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
    -p "$PORT" root@127.0.0.1 'journalctl --vacuum-size=5M >/dev/null 2>&1; fstrim -v /; fstrim -v /boot' 2>&1 | grep -v '^Warning' | tail -2
ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
    -p "$PORT" root@127.0.0.1 'poweroff' 2>/dev/null || true
i=0; while [ $i -lt 60 ] && pgrep -f qemu-system-aarch64 >/dev/null 2>&1; do sleep 2; i=$((i+2)); done

echo "== flattening -> $OUT"
qemu-img convert -O qcow2 "$OV" "$OUT"
rm -f "$OV" "$W/qemu.pid"

"$REPO/alloy/regression-test.sh" "$OUT" "$NAME"
"$REPO/alloy/quiescence-test.sh" "$OUT" "$NAME"
echo "== profile build complete: $OUT"
