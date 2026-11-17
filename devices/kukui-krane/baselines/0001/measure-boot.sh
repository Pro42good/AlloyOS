#!/bin/sh
# Timed headless boot: launch QEMU, poll SSH until auth succeeds.
# Usage: measure-boot.sh <img.qcow2> <serial.log> <timings.txt> [ssh_port] [vars.fd]
# Writes: t0 (qemu spawn), t1 (first successful SSH auth), boot_seconds.
set -eu
IMG="$1"; SERIAL="$2"; TIMINGS="$3"; PORT="${4:-2222}"; VARS="${5:-images/firmware/vars-pmos.fd}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
KH="$(cd "$(dirname "$0")/../.." && pwd)/alloy/known_hosts"

rm -f "$SERIAL" "$REPO/baselines/0001/qemu.pid"
T0="$(python3 -c 'import time;print(time.time())')"
"$REPO/scripts/run-qemu-headless.sh" "$IMG" "$SERIAL" "$REPO/baselines/0001/qemu.pid" "$PORT" "$VARS"

T1=""
for i in $(seq 1 300); do
  if ssh -o BatchMode=yes -o ConnectTimeout=2 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
        -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
    T1="$(python3 -c 'import time;print(time.time())')"
    break
  fi
  sleep 1
done

if [ -z "$T1" ]; then
  echo "TIMEOUT: SSH never became reachable" >&2
  exit 2
fi

python3 - "$T0" "$T1" "$TIMINGS" <<'EOF'
import sys
t0, t1, path = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
with open(path, "w") as f:
    f.write(f"t0_spawn={t0:.3f}\nt1_ssh_ready={t1:.3f}\nboot_seconds={t1-t0:.1f}\n")
EOF
cat "$TIMINGS"
