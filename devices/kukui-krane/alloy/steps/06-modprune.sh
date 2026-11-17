#!/bin/sh
# ALLOY stage 06 — kernel-module diet for qemu -M virt (keep-rules are the spec).
set -e
K="$(ls /lib/modules | head -1)"
M="/lib/modules/$K/kernel"

keep() {
  case "$1" in
    drivers/virtio/*|drivers/block/*|drivers/base/*|drivers/pci/*|drivers/video/*|drivers/dma-buf/*|drivers/crypto/*|drivers/acpi/*|drivers/firmware/*|drivers/rtc/*|drivers/tty/*|drivers/hid/*|drivers/input/*|drivers/nvme/host/*|drivers/i2c/*)
      return 0 ;;
    drivers/usb/host/*|drivers/usb/storage/*|drivers/usb/class/*|drivers/usb/misc/*|drivers/usb/serial/*)
      return 0 ;;
    drivers/net/tun.ko*|drivers/net/wireguard*|drivers/net/usb/*)
      return 0 ;;
    drivers/scsi/*.ko*) return 0 ;;
    drivers/gpu/drm/*.ko*|drivers/gpu/drm/ttm/*|drivers/gpu/drm/virtio/*|drivers/gpu/drm/scheduler/*|drivers/gpu/drm/clients/*)
      return 0 ;;
    sound/core/*|sound/hda/*|sound/usb/*|sound/drivers/*|sound/virtio/*|sound/pci/*)
      return 0 ;;
    net/netfilter/*|net/ipv4/*|net/ipv6/*|net/sched/*|net/llc/*|net/802/*|net/rfkill/*)
      return 0 ;;
    fs/fuse/*|fs/overlayfs/*|fs/nls/*)
      return 0 ;;
    crypto/*|arch/*|lib/crc/*|lib/math/*|lib/crypto/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

find "$M" -name '*.ko*' | sort > /tmp/all.lst
: > /tmp/drop.lst
while read -r f; do
  rel=${f#"$M"/}
  keep "$rel" || echo "$f" >> /tmp/drop.lst
done < /tmp/all.lst
echo "dropping $(wc -l < /tmp/drop.lst) of $(wc -l < /tmp/all.lst) module files"
while IFS= read -r f; do rm -f -- "$f"; done < /tmp/drop.lst
depmod -a "$K" 2>&1 | head -3 || true

# proofs: every loaded module (minus intentionally dropped) must resolve
FAILED=0
for m in $(awk '{print $1}' /proc/modules); do
  case "$m" in vsock|vmw_vsock_virtio_transport_common|vsock_loopback|libcomposite) continue ;; esac
  modprobe -n "$m" 2>/dev/null || { echo "CANNOT RESOLVE: $m"; FAILED=1; }
done
[ "$FAILED" = 0 ] && echo "loaded-module resolution: OK"
for m in tun wireguard snd_hda_intel uinput uhid hid_multitouch usbnet cdc_ether virtio_gpu sd_mod snd-aloop nft_ct xt_MASQUERADE; do
  modprobe -n "$m" 2>/dev/null || echo "MISSING boot/dev module: $m"
done
du -sk "/lib/modules/$K"
