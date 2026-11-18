#!/bin/sh
# Freeze artifacts: write a sha256 manifest and set the macOS immutable flag.
# Usage: freeze.sh <img.qcow2> [...]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <img> [...]"; exit 2; }
DIR="$(cd "$(dirname "$1")" && pwd)"
MAN="$DIR/FROZEN-$(date +%Y%m%d-%H%M).sha256"
cd "$DIR"
for f in "$@"; do
  b="$(basename "$f")"
  [ -f "$b" ] || { echo "missing: $f"; exit 2; }
done
shasum -a 256 "$@" | tee "$MAN"
for f in "$@"; do
  chflags uchg "$f" 2>/dev/null || echo "note: could not set uchg on $f (non-APFS?)"
done
echo "==> frozen: $(basename "$MAN") (+ uchg on $# artifact(s))"
echo "    unfreeze deliberately with: chflags nouchg <file>"
