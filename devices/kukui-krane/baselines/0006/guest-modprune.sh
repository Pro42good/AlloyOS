#!/bin/sh
# Kernel module prune for qemu -M virt. Keep-rules -> drop list -> delete -> depmod.
K="7.2.4"
M="/lib/modules/$K/kernel"
MROOT="/lib/modules/$K"

keep() {
  case "$1" in
    # core infrastructure dirs (kept wholesale)
    drivers/virtio/*|drivers/block/*|drivers/base/*|drivers/pci/*|drivers/video/*|drivers/dma-buf/*|drivers/crypto/*|drivers/acpi/*|drivers/firmware/*|drivers/rtc/*|drivers/tty/*|drivers/hid/*|drivers/input/*|drivers/nvme/host/*)
      return 0 ;;
    # usb: host/storage/class/misc/serial — not gadget/typec/phy/renesas/cdns3
    drivers/usb/host/*|drivers/usb/storage/*|drivers/usb/class/*|drivers/usb/misc/*|drivers/usb/serial/*)
      return 0 ;;
    # net extras that qemu/dev plausibly need
    drivers/net/tun.ko*|drivers/net/wireguard*|drivers/net/usb/*)
      return 0 ;;
    # scsi: root files only (sd_mod, sg, sr_mod...) — not vendor drivers
    drivers/scsi/*.ko*) return 0 ;;
    # drm: core files + ttm + virtio + scheduler + clients
    drivers/gpu/drm/*.ko*|drivers/gpu/drm/ttm/*|drivers/gpu/drm/virtio/*|drivers/gpu/drm/scheduler/*|drivers/gpu/drm/clients/*)
      return 0 ;;
    # sound: core, hda (ich9-intel-hda path), usb, drivers (snd-aloop/dummy), virtio — not soc
    sound/core/*|sound/hda/*|sound/usb/*|sound/drivers/*|sound/virtio/*|sound/pci/*)
      return 0 ;;
    # network stacks kept
    net/netfilter/*|net/ipv4/*|net/ipv6/*|net/sched/*|net/llc/*|net/802/*|net/rfkill/*)
      return 0 ;;
    # fs kept (ext4/vfat/zram builtin): fuse stack, overlay, nls for vfat
    fs/fuse/*|fs/overlayfs/*|fs/nls/*)
      return 0 ;;
    # crypto + arch accel + small libs (raid libs dropped with md)
    crypto/*|arch/*|lib/crc/*|lib/math/*|lib/crypto/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

BEFORE=$(du -sk /lib/modules/$K | cut -f1)
NFILES_BEFORE=$(find $MROOT -name '*.ko*' | wc -l)

find $M -name '*.ko*' | sort > /tmp/all.lst
: > /tmp/drop.lst
: > /tmp/keep.lst
while read -r f; do
  rel=${f#"$M"/}
  if keep "$rel"; then echo "$f" >> /tmp/keep.lst; else echo "$f" >> /tmp/drop.lst; fi
done < /tmp/all.lst

DROPN=$(wc -l < /tmp/drop.lst)
DROPSZ=$(du -sk $(cat /tmp/drop.lst) 2>/dev/null | awk '{s+=$1} END{print s/1024}')
echo "before: $BEFORE KB total, $NFILES_BEFORE module files"
echo "drop: $DROPN files, ${DROPSZ} MB"
echo "keep: $(wc -l < /tmp/keep.lst) files"

# apply
while IFS= read -r f; do rm -f -- "$f"; done < /tmp/drop.lst
depmod -a "$K" 2>&1 | head -3

AFTER=$(du -sk /lib/modules/$K | cut -f1)
echo "after: $AFTER KB total (freed $((BEFORE - AFTER)) KB)"

# resolution proofs
echo "== loaded modules must still resolve (except intentionally dropped):"
FAILED=0
for m in $(awk '{print $1}' /proc/modules); do
  case "$m" in vsock|vmw_vsock_virtio_transport_common|vsock_loopback|libcomposite) continue ;; esac
  if ! modprobe -n "$m" 2>/dev/null; then echo "  CANNOT RESOLVE: $m"; FAILED=1; fi
done
[ "$FAILED" = 0 ] && echo "  all loaded resolve OK"

echo "== boot/dev-critical modules must resolve:"
for m in tun wireguard snd_hda_intel uinput uhid hid_multitouch usbnet cdc_ether virtio_gpu sd_mod snd-aloop nft_ct xt_MASQUERADE; do
  if modprobe -n "$m" 2>/dev/null; then echo "  ok: $m"; else echo "  MISSING: $m"; fi
done

echo "== vsock/libcomposite now unresolvable (expected):"
for m in vsock libcomposite; do modprobe -n "$m" 2>/dev/null && echo "  still resolves: $m" || echo "  gone: $m"; done

cp /tmp/drop.lst /tmp/keep.lst /tmp/all.lst /tmp/ 2>/dev/null
mv /tmp/drop.lst /tmp/keep.lst "$OLDPWD" 2>/dev/null || true
rm -f /tmp/all.lst /tmp/drop.lst /tmp/keep.lst
