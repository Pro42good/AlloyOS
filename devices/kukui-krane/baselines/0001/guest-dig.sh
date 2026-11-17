#!/bin/sh
# Deep inventory of ALLOY-BASELINE-0001 (busybox sh + awk).
sec() { echo; echo "===== $1 ====="; }

sec "A. top 30 packages by installed size (I: field, bytes)"
awk '
/^P:/  { p = substr($0, 3) }
/^I:/  { printf "%12d %s\n", substr($0, 3), p }
' /lib/apk/db/installed | sort -rn | head -30 | awk '{ printf "%8.1f MB  %s\n", $1/1048576, $2 }'

sec "A2. package count + total"
awk '/^P:/{n++} /^I:/{s+=$2} END{printf "pkgs=%d bytes=%d (%.1f MB)\n", n, s, s/1048576}' /lib/apk/db/installed

sec "B. directory breakdown"
du -xm /usr/lib/* 2>/dev/null | sort -rn | head -18
echo "-- /usr/share:"
du -xm /usr/share/* 2>/dev/null | sort -rn | head -10
echo "-- /var:"
du -xm /var/* 2>/dev/null | sort -rn | head -8
echo "-- /etc:"
du -xm /etc/* 2>/dev/null | sort -rn | head -10
echo "-- /usr/bin + /usr/sbin:"
du -xm /usr/bin /usr/sbin 2>/dev/null

sec "C. /usr/lib/dri (mesa DRI drivers)"
du -xm /usr/lib/dri
ls -lk /usr/lib/dri | awk '$5 > 0 {printf "%6d KB  %s\n", $5, $9}' | sort -rn | head -12

sec "D. LLVM linkage check"
ldd /usr/lib/dri/panfrost_dri.so 2>/dev/null | grep -ci llvm
ldd /usr/lib/dri/swrast_dri.so 2>/dev/null | grep -ci llvm
ldd /usr/lib/dri/virtio_gpu_dri.so 2>/dev/null | grep -ci llvm
du -xm /usr/lib/llvm* 2>/dev/null
ls -lk /usr/lib/libLLVM* 2>/dev/null

sec "E. kernel + modules"
cat /proc/modules | wc -l
awk '{printf "%6d KB  %s\n", $2/1024, $1}' /proc/modules | sort -rn | head -10
du -xm /lib/modules/*
du -xm /lib/modules/*/kernel/* 2>/dev/null | sort -rn | head -10

sec "F. /boot (ESP) + initramfs"
mount | grep boot
ls -lk /boot
du -sk /boot/dtbs 2>/dev/null
cat /etc/mkinitfs/mkinitfs.conf 2>/dev/null

sec "G. journal + /var/log"
journalctl --disk-usage 2>/dev/null | tail -1
du -xm /var/log /var/lib /var/cache 2>/dev/null

sec "H. systemd: timers / cgtop mem / enabled units"
systemctl list-timers --all --no-pager --no-legend | awk '{printf "%-42s next=%s\n", $NF, $2}'
systemd-cgtop -m -b -n 1 2>/dev/null | head -22
systemctl list-unit-files --state=enabled --no-pager --no-legend | wc -l

sec "I. GUI stragglers check"
apk info 2>/dev/null | grep -E '^(gtk|dconf|shared-mime|gsettings|adwaita|hicolor|wayland|libx11|libxcb|libxau|fontconfig|freetype|pango|cairo|harfbuzz|seatd|libseat|lang)' | head -20
echo "-- -lang packages still installed:"
apk info | grep -- -lang | head -10

sec "J. quick idle attribution (30s)"
sleep 5
cat /proc/interrupts > /tmp/j0
grep '^intr ' /proc/stat > /tmp/k0
sleep 30
cat /proc/interrupts > /tmp/j1
grep '^intr ' /proc/stat > /tmp/k1
S0=$(awk '{print $2}' /tmp/k0); S1=$(awk '{print $2}' /tmp/k1)
echo "30s irq delta: $((S1 - S0)) = $(awk -v d=$((S1-S0)) 'BEGIN{printf "%.2f", d/30}')/s"
awk 'NR == FNR { n = split($0, f, /[ \t]+/); s = 0; for (j = 2; j <= n; j++) if (f[j] ~ /^[0-9]+$/) s += f[j]; base[FNR] = s; next }
{ n = split($0, f, /[ \t]+/); s = 0; for (j = 2; j <= n; j++) if (f[j] ~ /^[0-9]+$/) s += f[j]; d = s - base[FNR]; if (d > 0) printf "%6d %s\n", d, substr($0, 1, 60) }' /tmp/j0 /tmp/j1 | sort -rn | head -6
rm -f /tmp/j0 /tmp/j1 /tmp/k0 /tmp/k1

sec "K. systemd components on disk"
du -xm /usr/lib/systemd /usr/share/factory /usr/lib/sysusers.d /usr/lib/udev /usr/lib/kernel 2>/dev/null | sort -rn | head -8

sec "L. misc"
cat /proc/sys/vm/swap_in_swap_out 2>/dev/null
zram_total() { apk info -e postmarketos-zram-swap 2>/dev/null; }
zram_total
cat /sys/block/zram0/disksize 2>/dev/null | awk '{printf "zram0 disksize: %.0f MB\n", $1/1048576}'
du -xm /usr/libexec /usr/share/terminfo /usr/lib/ssh /usr/libexec/sudo* 2>/dev/null | sort -rn | head -8
