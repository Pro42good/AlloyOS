#!/bin/sh
# Reproducible ALLOY Core build: pristine image -> CORE, 8 gated stages.
# Usage: build-core.sh [src.qcow2] [out.qcow2]
#   src defaults to the frozen ALLOY-GUI-0000 (pristine Phosh image);
#   out defaults to alloy/core/alloy-core.qcow2.
# Every stage boots in a throwaway overlay, applies one steps/NN-*.sh, and the
# final artifact must pass regression-test.sh + quiescence-test.sh (core gates).
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KH="$(cd "$(dirname "$0")" && pwd)/known_hosts"
SRC="${1:-$REPO/images/pmos-qemu-aarch64.qcow2}"
OUT="${2:-$REPO/alloy/core/alloy-core.qcow2}"
case "${BASE:-phosh}" in
  phosh) STRIP=01-strip; PROFILE=core ;;
  console) STRIP=01-strip-nura; PROFILE=core-nura ;;
  *) echo "BASE must be phosh or console" >&2; exit 2 ;;
esac
W="$REPO/alloy/build"
LOGS="$W/logs"; mkdir -p "$LOGS" "$(dirname "$OUT")"
PORT=2222
# SECURITY_AUDIT HIGH-2/MED-4: password only transits the encrypted SSH
# channel via the expect helper (env, not argv, not a pipe); the sudo prompt
# is answered in-session, and every call after the first is key-auth against
# the pinned host key.
[ -f "$HOME/.ssh/id_ed25519.pub" ] || { echo "error: no SSH key at ~/.ssh/id_ed25519.pub"; exit 1; }
PUB_B64="$(base64 < "$HOME/.ssh/id_ed25519.pub" | tr -d '\n')"   # shell-safe alphabet
# SECURITY_AUDIT2 HIGH-1: no default fallback - the operator states the
# credential explicitly. (Fresh pmOS images ship user/147147; rotate it in
# the guest post-bootstrap if you want per-build secrets.)
: "${PMOS_PASS:?set PMOS_PASS to the image user password (fresh pmOS default: see README)}"

VARS_SEED="${VARS:-$REPO/baselines/0007/vars.fd}"
if [ -f "$VARS_SEED" ]; then
  cp "$VARS_SEED" "$W/vars.fd"
else
  rm -f "$W/vars.fd"
fi
PREV="$SRC"
N=0
for STEP in 00-keys "$STRIP" 02-filecuts 03-hwdb 04-tuning 05-swap 06-modprune 07-configs; do
  N=$((N+1))
  OV="$W/s$N.qcow2"
  rm -f "$OV" "$W/serial.log" "$W/qemu.pid"
  qemu-img create -f qcow2 -F qcow2 -b "$PREV" "$OV" >/dev/null
  echo "== stage $N/8: $STEP (backing: $(basename "$PREV"))"
  "$REPO/scripts/run-qemu-headless.sh" "$OV" "$W/serial.log" "$W/qemu.pid" "$PORT" "$W/vars.fd"

  if [ "$STEP" = "00-keys" ]; then
    # SECURITY_AUDIT HIGH-2: pin the guest host key first (TOFU once, local
    # VM, loopback only, BEFORE any credential moves), then bootstrap with
    # expect answering the login + sudo prompts in-session. No pipes, no
    # password in argv, no password in the process list.
    ssh-keyscan -p "$PORT" -T 10 127.0.0.1 2>/dev/null > "$W/keyscan.raw"
    [ -s "$W/keyscan.raw" ] || { echo "keyscan produced nothing"; exit 2; }
    echo "==> pinning guest host keys (verify fingerprints):"
    ssh-keygen -l -f "$W/keyscan.raw" || exit 2
    grep -v '^\[127.0.0.1\]:' "$KH" > "$W/kh.new" 2>/dev/null || printf '' > "$W/kh.new"
    cat "$W/keyscan.raw" >> "$W/kh.new"
    mv "$W/kh.new" "$KH"          # atomic replace, no stale accumulation
    "$REPO/baselines/0001/ssh-run.exp" "$PORT" user \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUB_B64' | base64 -d >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
      >/dev/null 2>&1
    "$REPO/baselines/0001/ssh-run.exp" "$PORT" user \
      "sudo sh -c 'mkdir -p /root/.ssh && cp /home/user/.ssh/authorized_keys /root/.ssh/ && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys'" \
      >/dev/null 2>&1
    scp -q -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
        -P "$PORT" "$REPO"/alloy/keys/*.pub root@127.0.0.1:/etc/apk/keys/
    WAIT=240
  else
    WAIT=120
  fi

  # wait for BatchMode root
  UP=0
  i=0; while [ $i -lt $WAIT ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
           -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
      UP=1; break
    fi
    sleep 2; i=$((i+2))
  done
  [ "$UP" = 1 ] || { echo "stage $STEP: SSH never came up"; exit 2; }
  sleep 10   # settle past first-boot journald flush

  ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -p "$PORT" root@127.0.0.1 'sh -s' < "$REPO/alloy/steps/$STEP.sh" \
      2>&1 | grep -v '^Warning' | tee "$LOGS/$STEP.log"

  ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -p "$PORT" root@127.0.0.1 'poweroff' 2>/dev/null || true
  i=0; while [ $i -lt 60 ] && pgrep -f qemu-system-aarch64 >/dev/null 2>&1; do
    sleep 2; i=$((i+2))
  done
  # flatten per stage: chained overlays read deleted LBAs through to the source
  # image (qcow2 rm does not write LBAs), carrying ~800 MB of residue into the
  # final flatten. Per-stage converts keep each layer honest (matches the
  # original 0001-0007 methodology).
  qemu-img convert -O qcow2 "$OV" "$W/stage$N.qcow2"
  rm -f "$OV"
  [ "$N" -lt 8 ] && PREV="$W/stage$N.qcow2"
done

echo "== flattening -> $OUT"
qemu-img convert -O qcow2 -c "$W/stage8.qcow2" "$OUT"   # -c: compressed core
rm -f "$W"/s*.qcow2 "$W"/stage*.qcow2 "$W/qemu.pid"

echo "== gates"
VARS="$W/vars.fd" "$REPO/alloy/regression-test.sh" "$OUT" "$PROFILE"
VARS="$W/vars.fd" "$REPO/alloy/quiescence-test.sh" "$OUT" "$PROFILE"
echo "== CORE build complete: $OUT"
