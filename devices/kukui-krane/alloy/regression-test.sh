#!/bin/sh
# ALLOY regression harness — functional integrity of any Core-derived artifact.
# Usage: regression-test.sh <img.qcow2> [profile]   (profile: core|prod|dev|lab)
# Boots the image on a throwaway overlay (frozen files allowed), runs checks,
# powers off, reports PASS/FAIL per check. Exit 0 only if all pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KH="$(cd "$(dirname "$0")" && pwd)/known_hosts"
VARS="${VARS:-$REPO/baselines/0007/vars.fd}"
IMG="$1"; PROFILE="${2:-core}"
W="$(mktemp -d /var/folders/jd/vql7k8454mzg89l6vrnjh_t80000gn/T/opencode/reg.XXXXXXXX)"
PORT=2222
FAIL=0
SSHCM="-o ControlMaster=auto -o ControlPath=$W/cm -o ControlPersist=300"

qemu-img create -f qcow2 -F qcow2 -b "$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")" "$W/ov.qcow2" >/dev/null
"$REPO/scripts/run-qemu-headless.sh" "$W/ov.qcow2" "$W/serial.log" "$W/qemu.pid" "$PORT" \
    "$VARS"
UP=0; i=0
while [ $i -lt 240 ]; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
      -p "$PORT" root@127.0.0.1 true 2>/dev/null && { UP=1; break; }
  sleep 2; i=$((i+2))
done
if [ "$UP" = 1 ]; then :; else echo "REGRESSION: image never booted"; kill "$(cat "$W/qemu.pid" 2>/dev/null)" 2>/dev/null; true; rm -rf "$W"; exit 2; fi
sleep 20

G() { # multiplexed ssh with retry-on-connection-failure; rc=0 empties pass through
  local n=0 out rc
  while [ $n -lt 3 ]; do
    out="$(ssh $SSHCM -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
        -p "$PORT" root@127.0.0.1 "$1" 2>/dev/null)"
    rc=$?
    [ $rc -eq 0 ] && { printf '%s' "$out" | grep -v '^Warning'; return 0; }
    n=$((n+1)); sleep 2
  done
  return 1
}
P() { if [ "$1" = 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; FAIL=1; fi; }

echo "== regression ($PROFILE): $IMG"
echo "-- keep-list packages"
for p in device-qemu-aarch64-kernel-stable linux-firmware-none mesa mesa-dri-gallium \
         pipewire wireplumber alsa-lib alsa-utils libinput networkmanager openssh \
         bluez wpa_supplicant polkit dbus-broker systemd postmarketos-base \
         postmarketos-mkinitfs sudo-rs agetty; do
  R="$(G "apk info -e $p 2>/dev/null")"
  P $? "pkg $p"
done

echo "-- files"
G 'ls /usr/lib/dri/panfrost_dri.so >/dev/null 2>&1'; P $? "panfrost_dri.so"

echo "-- config surface"
case "$PROFILE" in
  dev|lab) FWD_EXP="yes"; FWD_TXT="forwarding yes (dev/lab)" ;;
  *)       FWD_EXP="no";  FWD_TXT="forwarding no (core/prod)" ;;
esac
[ "$(G "sshd -T 2>/dev/null | grep -ci \"^allowtcpforwarding $FWD_EXP\"")" = 1 ]; P $? "sshd $FWD_TXT"
G 'grep -q "psi=0" /proc/cmdline && grep -q "transparent_hugepage=madvise" /proc/cmdline'; P $? "cmdline (psi=0, THP=madvise)"
[ "$(G 'sysctl -n vm.compaction_proactiveness')" = 0 ]; P $? "compaction_proactiveness=0"
[ "$(G 'sysctl -n vm.stat_interval')" = 10 ]; P $? "stat_interval=10"
G 'test -f /etc/systemd/journald.conf.d/10-alloy-cap.conf'; P $? "journald cap"

echo "-- runtime"
[ "$(G 'systemctl --failed --no-legend | wc -l | tr -d " "')" = 0 ]; P $? "failed units = 0"
for s in NetworkManager sshd systemd-resolved systemd-timesyncd systemd-udevd dbus-broker serial-getty@ttyAMA0 getty@tty1; do
  [ "$(G "systemctl is-active $s")" = active ]; P $? "$s active"
done
N_Z="$(G 'grep -c zram /proc/swaps')"; N_F="$(G 'grep -c swapfile /proc/swaps')"
[ "${N_Z:-0}" -ge 1 ] && [ "${N_F:-0}" -ge 1 ]; P $? "swap layering (zram + file)"
MODS="$(G 'find /lib/modules -name "*.ko*" | wc -l | tr -d " "')"; MODSZ="$(G 'du -sk /lib/modules | cut -f1')"
MODS="${MODS:-0}"; MODSZ="${MODSZ:-0}"
if [ "$MODS" -le 700 ] && [ "$MODSZ" -le 30720 ]; then
  echo "  PASS  modules $MODS files / $((MODSZ/1024)) MB"
else echo "  FAIL  modules regrew: $MODS files / $((MODSZ/1024)) MB"; FAIL=1; fi
NS="$(G 'netstat -tln 2>/dev/null')"
LL="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 ~ /:5355$/' | wc -l | tr -d ' ')"
TOT="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 ~ /:/' | wc -l | tr -d ' ')"
BAD="$(printf '%s\n' "$NS" | awk 'NR>2 && $4 !~ /:(22|53)$/' | wc -l | tr -d ' ')"
if [ "$LL" = 0 ] && [ "$TOT" = 4 ] && [ "$BAD" = 0 ]; then
  echo "  PASS  listeners = {22, 53, 53} (no 5355)"
else echo "  FAIL  listeners ($TOT total, $LL llmnr, $BAD unexpected)"; FAIL=1; fi
# input classification: read the authoritative udev db directly.
# (known quirk: `udevadm info -q property <dev>` intermittently fails to merge
# db tags on this udev build; --export-db reads the db files directly and is
# reliable — see ALLOY-BASELINE-0007 gotchas)
IN=1
n=0
while [ $n -lt 3 ]; do
  sleep 5
  N_IN="$(G 'udevadm info --export-db 2>/dev/null | grep -c "^E: ID_INPUT=1"')"
  [ "${N_IN:-0}" -ge 1 ] && { IN=0; break; }
  n=$((n+1))
done
P $IN "input classification"

echo "-- profile extras"
case "$PROFILE" in
  prod)
    [ "$(G 'sshd -T 2>/dev/null | grep -ci "^passwordauthentication no"')" = 1 ]; P $? "prod: password auth off"
    G 'test -f /etc/systemd/journald.conf.d/20-prod.conf'; P $? "prod: volatile journal"
    [ "$(G 'nft list ruleset 2>/dev/null | wc -l | tr -d " "')" -gt 2 ]; P $? "prod: nftables ruleset"
    ;;
  dev) G 'command -v gcc >/dev/null'; P $? "dev: toolchain" ;;
  lab) G 'test -x /opt/alloy/collect-metrics.sh'; P $? "lab: /opt/alloy tooling" ;;
esac

ssh $SSHCM -o BatchMode=yes -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes \
    -p "$PORT" root@127.0.0.1 'poweroff' 2>/dev/null || true
sleep 8
rm -rf "$W"
if [ "$FAIL" = 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES PRESENT"; exit 1; fi
