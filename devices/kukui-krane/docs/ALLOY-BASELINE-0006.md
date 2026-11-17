# ALLOY-BASELINE-0006

**Sixth measured reduction**: kernel-module diet. Of the 2176 module files the
distro kernel ships (72.8 MB), this hardware — QEMU `-M virt` with virtio +
USB HID + optional virtio GPU/sound — can ever load a small set. Everything
else is dead weight that udev's modalias machinery can never trigger. Deleted,
`depmod`-ed, and proven to boot with zero functionality loss.

| | |
|---|---|
| ID | ALLOY-BASELINE-0006 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0005 (`baselines/0005/alloy-baseline-0005.qcow2`, kept pristine) |
| Artifact | `baselines/0006/alloy-baseline-0006.qcow2` (692 MiB) |
| Packages | 267 — unchanged (file-level prune inside the kernel package's tree) |
| Health | 0 failed units; boots 12.3–12.5 s; all loaded modules still resolve |

---

## 1. What this hardware can actually be

`qemu-system-aarch64 -M virt` presents: virtio (blk/net/gpu/sound/rng/9p/
console/fs/crypto), qemu-xhci USB (kbd/tablet/storage/audio/net), optional
ich9-intel-hda, optional NVMe, tun/wireguard for networking work. The
critical boot stack is **builtin** in this kernel: `ext4`, `vfat`, `zram`,
`drm`, `virtio_blk`, `virtio_net`. That defines the keep-set.

**Keep-rules** (mechanical, in `baselines/0006/guest-modprune.sh`):

| Kept | Why |
|---|---|
| `drivers/{virtio,block,base,pci,video,dma-buf,crypto,acpi,firmware,rtc,tty,nvme/host}` | core/virtio infrastructure; NVMe for a plausible `-device nvme` |
| `drivers/usb/{host,storage,class,misc,serial}` | qemu-xhci, usb-storage/uas, serial gadgets |
| `drivers/net/{tun,wireguard,usb/}` | dev networking (tun/wg), qemu `usb-net` |
| `drivers/scsi/*.ko` root files only (sd_mod, sg) | uas/usb-storage deps |
| `drivers/gpu/drm/{*.ko,ttm,virtio,scheduler,clients}` | virtio-gpu + fb console; **all vendor DRM dropped** |
| `sound/{core,hda,usb,drivers,virtio}` | ich9-intel-hda, usb-audio, snd-aloop/dummy for headless audio tests, virtio-sound; **ASoC/SoC codecs dropped** |
| `net/{netfilter,ipv4,ipv6,sched,llc,802,rfkill}` | nftables is active |
| `fs/{fuse,overlayfs,nls}` | loaded fuse stack, future containers, vfat iocharset |
| `crypto/*, arch/*, lib/{crc,math,crypto}` | small, generally useful |
| `drivers/{hid,input}` wholesale | usb-kbd/tablet/touch, `uinput`+`uhid` required by `modules-load.d` |

**Dropped**: wireless (11 MB + mac80211), ethernet (6 MB), sound/soc incl. all
MT8183/SoC codecs (7 MB), media (5 MB), vendor DRM — amd/xe/nouveau/panfrost/
lima/panthor/mediatek/rockchip/… (9 MB), bluetooth stack, NFC, CAN, DSA, WWAN,
SCSI vendor drivers, ATA, mtd/mmc/ufs, platform (SoC/phy/pinctrl/regulator/
power/power-supply), i2c, iio, gpio, clk vendors, thermal, xen, vhost,
sunrpc/NFS/9p/CIFS/Btrfs/XFS/EROFS/exFAT/NTFS, raid libs, xdp/… — plus the
loaded-but-unused **vsock trio and `libcomposite`** (gadget UDC does not exist
on qemu virt; the masked `usb-signaller` is the only consumer).

## 2. Numbers

| | before | **after** |
|---|---|---|
| Module files | 2176 | **625** |
| `/lib/modules/7.2.4` | 72.8 MB | **23.3 MB** (−48.3 MB) |
| Image (qcow2) | 734 MiB | **692 MiB** |
| Idle wakeups | 8.73/s | **6.92/s** (arch_timer 5.83/s) |
| Boot RAM | 98 MiB | 105 MiB (noise band; ±7 across boots) |
| Modules loaded at runtime | 10 | **7** (vsock trio gone) |
| Boot → SSH (median-of-3) | 12.4 s | **12.5 / 12.4 / 12.3 s** |
| systemd-analyze | 9.29 s | 9.31 s |

The wakeup bonus (−21 %) is plausible-but-not-fully-explained: a 4× smaller
module/alias set makes udev coldplug cheaper and removes the vsock/rfkill
workqueue churn; treat as measured-but-not-fully-attributed.

## 3. Verification

- `depmod -a 7.2.4` regenerated `modules.{dep,alias,softdep,devname}`
- **All modules loaded at boot still resolve** (`modprobe -n` against the new
  indexes) — checked explicitly, none silently broken
- Boot/dev-critical set resolves: `tun wireguard snd_hda_intel uinput uhid
  hid_multitouch usbnet cdc_ether virtio_gpu sd_mod snd-aloop nft_ct
  xt_MASQUERADE`
- `vsock` and `libcomposite` intentionally unresolvable (nothing requests them)
- Fresh boot: 7 modules loaded; `systemd-modules-load` active (uinput/uhid);
  eth0 DHCP, zram swap, 3 event devices with correct `ID_INPUT_*`, apk + DNS
  fine, fstrim fine, 0 failed units. Serial-log error scan: only pre-existing
  EDK2 firmware noise (TPM probe, ConvertPages), no module errors.
- Note: `libcomposite` still *appears* loaded after reboot — the **initramfs
  carries its own module copies** and the pmOS USB log-export attempt loads it
  from there. Harmless, pre-existing, unrelated to the pruned tree.

## 4. What "load later when hardware requires it" means here

The loading model already is on-demand: udev matches device `modalias` against
`modules.alias` and kmod loads what matches. Pruning does not change that for
kept modules — it only removes aliases that this machine can never emit. If
the runner is ever extended (e.g. `-device e1000`, real WiFi passthrough), the
missing modules come back with:

```sh
apk fix linux-postmarketos-stable      # re-installs the package's files
depmod -a 7.2.4
```

…and any such runner change must be re-measured (the baseline is pinned to
the documented runner geometry). The real Krane uses a different kernel
package (`linux-postmarketos-mediatek-mt8183`) with its own module set — this
prune defines the *QEMU artifact*, not the Krane image.

**apk deviation note**: the pruned files belong to
`linux-postmarketos-stable`; `apk audit` will list them as missing and any
kernel upgrade restores them. That is the accepted, documented trade-off of
doing this without forking the package. Snapshots (parent artifacts) are the
rollback path.

## 5. Metrics context

| | 0004 | 0005 | **0006** |
|---|---|---|---|
| Image | 719 MiB | 734 MiB | **692 MiB** |
| Boot RAM | 101 MiB | 98 MiB | 105 MiB (noise band) |
| Idle wakeups | 11.4/s | 8.73/s | **6.92/s** |
| Modules on disk | 72.8 MB | 72.8 MB | **23.3 MB** |
| Boot → SSH | 12.4 s | 12.4 s | 12.4 s |
| Packages / payload | 267 / 632 MB | 267 / 632 MB | 267 / 632 MB |

## 6. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0006/alloy-baseline-0006.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0006/vars.fd
# prune logic: baselines/0006/guest-modprune.sh (keep-rules table = the spec)
# battery:    baselines/0001/measure-boot.sh + collect-metrics.sh as before
```

Artifacts in `baselines/0006/`: `alloy-baseline-0006.qcow2`, `overlay-0006.qcow2`,
`vars.fd`, `guest-modprune.sh`, `timings-b{1,2,3}.txt`, `serial-*.log`,
`out/{modprune.txt,baseline-0006.*}`.

---
*Measured 2026-09-08. Cumulative from the Phosh image: 2208 → 692 MiB (−69 %),
183 → ~100 MiB boot RAM, 27 → 12 services, 114.9 → 6.92 IRQ/s (−94 %), 1187 →
267 packages, 2176 → 625 module files — kernel, firmware, Mesa/Panfrost,
systemd, net/audio/input, and SSH verified intact at every step.*
