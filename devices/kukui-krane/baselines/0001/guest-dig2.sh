#!/bin/sh
# Follow-up: reverse deps + size verification for strip candidates.
sec() { echo; echo "===== $1 ====="; }

sec "1. exact sizes: dri dir, libdril, libgallium, libLLVM"
du -sk /usr/lib/dri
stat -c "%s %n" /usr/lib/dri/libdril_dri.so /usr/lib/libgallium-*.so /usr/lib/libLLVM.so.22.1 2>/dev/null
apk info -e mesa-dri-gallium && awk '/^P:mesa-dri-gallium$/,/^$/' /lib/apk/db/installed | grep -E '^I:'

sec "2. who links LLVM?"
ldd /usr/lib/dri/libdril_dri.so 2>/dev/null | grep -iE "llvm|not found"
ldd /usr/lib/libgallium-*.so 2>/dev/null | grep -iE "llvm|not found"
echo "-- llvmpipe present? (classic swrast needs LLVM):"
ls /usr/lib/dri/*swrast* 2>/dev/null
nm -D /usr/lib/libgallium-*.so 2>/dev/null | grep -c "llvmpipe" || true

sec "3. reverse deps via installed db"
for target in llvm22-libs spirv-tools mesa-dri-gallium libx11 libxcb wayland-libs-client xkeyboard-config cracklib-words nss xfsprogs-extra libseat; do
  echo "--- $target is required by:"
  awk -v t="$target" '
    /^P:/   { p = substr($0, 3) }
    /^D:/   { n = split(substr($0, 3), deps, " "); for (i = 1; i <= n; i++) { split(deps[i], d, "="); split(d[1], b, "<"); split(b[1], c, ">"); if (c[1] == t) print "  " p } }
  ' /lib/apk/db/installed | head -8
done

sec "4. vulkan / gl related packages installed?"
apk info | grep -iE "vulkan|zink|lavapipe|spirv" || echo "(none)"

sec "5. loader entries (devicetree refs?)"
cat /boot/loader/entries/*.conf

sec "6. mkinitfs config"
ls -la /etc/mkinitfs/ 2>/dev/null
cat /etc/mkinitfs/mkinitfs.conf 2>/dev/null || echo "(no conf)"

sec "7. dtbs dir exact + System.map"
du -sk /boot/dtbs
ls /boot/dtbs/ | head -5
ls /boot/dtbs/* 2>/dev/null | head -8
stat -c "%s %n" /boot/System.map /boot/config /boot/vmlinuz /boot/initramfs

sec "8. /etc/udev 14MB breakdown"
du -sk /etc/udev/* 2>/dev/null | sort -rn | head -5
ls /etc/udev/rules.d/ 2>/dev/null

sec "9. leftover users + homes"
grep -E "greetd|geoclue|polkitd|pulse|avahi" /etc/passwd
ls /var/lib/ | tr "\n" " "; echo

sec "10. what uses libx11/libxcb/wayland (runtime check)"
lsof 2>/dev/null | grep -cE "libX11|libxcb" || true
apk info -e libx11 && echo "libx11 installed"

sec "11. initramfs contents sample"
busybox cpio -t -i < /dev/null 2>/dev/null | head -1
gzip -dc /boot/initramfs 2>/dev/null | busybox cpio -t 2>/dev/null | head -3
gzip -dc /boot/initramfs 2>/dev/null | busybox cpio -t 2>/dev/null | wc -l

sec "12. swcatalog + greetd exact"
du -sk /var/lib/swcatalog /var/lib/greetd /var/lib/flatpak /var/lib/geoclue /var/lib/plymouth 2>/dev/null

sec "13. zram + mkinitfs module copies in initramfs"
gzip -dc /boot/initramfs 2>/dev/null | busybox cpio -t 2>/dev/null | grep -E "\.ko$|lib/firmware" | head -10
gzip -dc /boot/initramfs 2>/dev/null | busybox cpio -t 2>/dev/null | grep -c "\.ko$"
