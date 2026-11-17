#!/bin/sh
# Download the OFFICIAL postmarketOS google-kukui image (covers Krane).
# Real HW image — for flashing to the Duet / analysis. Will NOT boot in QEMU virt.
# Integrity: sha256 verified automatically against the published checksum.
set -eu
OUT_DIR="$(cd "$(dirname "$0")/../images" && pwd)"
BASE="https://images.postmarketos.org/bpo/v25.12/google-kukui/phosh/20260803-0403"
FILE="20260803-0403-postmarketOS-v25.12-phosh-25-google-kukui.img.xz"
# SECURITY_AUDIT2 MED-5: pin the expected digest (cross-channel trust anchor;
# verified against the published .sha256 on first download 2026-09-08).
EXPECTED="3165c349cfb1f7eea0aabf98203826d282dd727c43511dab50ced76452304bdf"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
if [ ! -f "$FILE" ]; then
  echo "==> downloading $FILE (~591MB) ..."
  curl --proto '=https' --tlsv1.2 -fL -o "$FILE" "$BASE/$FILE"
else
  echo "==> already present: $FILE"
fi
echo "==> verifying sha256 (SECURITY_AUDIT MED-1: automatic, fails hard) ..."
GOT="$(shasum -a 256 "$FILE" 2>/dev/null | awk "{print \$1}")"
GOT="$(printf "%s" "$GOT" | tr -cd "0-9a-f")"
if [ "$GOT" = "$EXPECTED" ]; then
  echo "==> OK: pinned sha256 matches"
else
  echo "==> ERROR: sha256 mismatch (got $GOT, want $EXPECTED) — deleting" >&2
  rm -f "$FILE"
  exit 1
fi
curl -sS --proto '=https' --tlsv1.2 -o "$FILE.sha256" "$BASE/$FILE.sha256"
echo "==> decompress with: unxz -k $FILE  (gives ~2-3GB .img)"
echo "==> inspect partitions: qemu-img info <img>; fdisk -l <img>; mount -o loop,offset=... <img> /mnt"
echo "==> kernel/dtb live in /boot (vmlinuz.kpart for depthcharge) + /lib/modules + /usr/share/dtb"
