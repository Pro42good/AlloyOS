# THE ALLOY PACKET — postmarketOS Phosh image → ALLOY-BASELINE-0007

**The complete, self-contained record of the ALLOY program**: what the floor
is, how every number in it was earned, everything that failed on the way, and
how to reproduce or reverse any of it. This document supersedes the per-step
records for narrative purposes; those (`ALLOY-BASELINE-000{1..7}.md`,
`ALLOY-PROFILE-0004-RUNTIME.md`, `ALLOY-PROCEDURE-0001-to-0005.md`) remain as
primary evidence with raw outputs in `baselines/*/out/`.

---

## 1. Executive summary

Starting from an ordinary mutable postmarketOS **edge / Phosh / systemd**
image for `qemu-aarch64` (built by pmbootstrap, 2208 MiB), the system was
stripped and tuned in **seven measured steps** to a development floor that
keeps exactly: kernel, firmware, Mesa (with Panfrost driver), systemd,
networking/audio/input essentials, and SSH — and nothing graphical. All
changes are stock-pmOS configuration (no forks, no patches, no custom
packages), and every step is individually reversible.

| | Phosh start | **0007 floor** | Δ |
|---|---|---|---|
| Image (qcow2) | 2208 MiB | **698 MiB** | −68 % |
| Packages / payload | 1187 / 2081 MB | **267 / 632 MB** | −78 % |
| Boot RAM (used) | 183 MiB | **96 MiB** | −48 % |
| Processes / services | 130 / 27 | **100 / 12** | −23 % / −56 % |
| Idle wakeups | 114.9 IRQ/s | **7.1 IRQ/s** | **−94 %** |
| Kernel module files | 2176 (72.8 MB) | **625 (23.3 MB)** | −68 % |
| Boot → SSH | 12.5 s | **12.5 s** | unchanged (firmware-bound) |

**Deliberately kept (the floor):** linux-stable 7.2.4 kernel +
postmarketos-mkinitfs; linux-firmware-none (virt needs no blobs); Mesa +
mesa-dri-gallium (**`panfrost_dri.so` present**) + EGL/GBM; systemd full +
dbus-broker + polkit; NetworkManager + wpa_supplicant + systemd-resolved +
systemd-timesyncd; PipeWire + WirePlumber + ALSA set + rtkit; libinput +
udev; OpenSSH (client+server) + sudo-rs; bluez; agetty + getty@tty1 +
serial-getty@ttyAMA0; hkdm + routewrangler (pmOS mobile plumbing, tiny);
font-terminus; apk-tools; zram (zstd) + 2 GB disk-swap overflow.

## 2. Ground rules (invariant across all seven steps)

1. **Write-isolation**: each state is a qcow2 overlay backed by the previous
   artifact; the delivered artifact is a flattened `qemu-img convert` of the
   overlay. The Phosh source image and every parent are preserved bootable
   (0001–0007 all exist in `baselines/<id>/`).
2. **Fixed measurement geometry** — every number in this packet was taken
   under exactly: `-M virt,highmem=on -accel hvf -cpu host -smp 4 -m 4096`,
   virtio-blk (discard=unmap), virtio-net (hostfwd 127.0.0.1:2222→22),
   qemu-xhci + usb-kbd + usb-tablet, no display device, headless, serial to
   logfile, EDK2 pflash + per-step NVRAM vars.
3. **Methodology** (hardened over the steps): idle the host ≥30 s before
   timed boots; median-of-3 boots; collect metrics ≥2 min post-boot (the
   collector hangs racing first-boot journald); wakeups = Δ(`/proc/interrupts`
   sum) over a 60 s window after a 15 s settle, measured in-guest;
   process counts include ~5 procs of the SSH measurement session itself;
   trim **both** filesystems (`fstrim -v /` and `-v /boot` — vfat needs its
   own) before compacting.
4. **Everything reversible**: configs are drop-ins, enablement is
   `systemctl`, file cuts are restorable from parent artifacts or
   `apk fix linux-postmarketos-stable`. Failed experiments are recorded as
   failed; nothing was assumed — measured.

## 3. State 0000 — the source

- Built by pmbootstrap 3.11.1 inside Docker (`pmb-kukui-lab`, Ubuntu 24.04),
  device `qemu-aarch64`, channel **edge (systemd)**, UI **Phosh**, with a
  manual disk-assembly fixup (Docker cannot expose loop partitions) — full
  story in the lab README §12. Final artifact: `images/pmos-qemu-aarch64.qcow2`.
- Boot chain: EDK2 AArch64 (brew QEMU firmware) → systemd-boot → pmOS
  initramfs (stage 1+2) → systemd. Credentials: `user` / `147147`.
- Known defects found on first contact: **empty `/etc/apk/keys`** (all repos
  UNTRUSTED — fixed by copying the 19-key ring from the pmbootstrap chroot);
  a stale README claim of 3.5 GiB used root (measured: 2.0 GB / 1.3 G free);
  the initramfs attempts USB-gadget log export that can never work on `virt`
  (harmless noise, `usb-signaller` masked, `libcomposite` loads from the
  initramfs's own module copy).

## 4. Harness

- `scripts/run-qemu-headless.sh` — daemonized boot per the fixed geometry.
- `baselines/0001/measure-boot.sh` — python3 t0 (pre-spawn) → BatchMode-SSH
  poll → t1; writes `boot_seconds`.
- `baselines/0001/collect-metrics.sh` + `guest-wakeups.sh` — system context,
  RAM (`free`, `/proc/meminfo`, dmesg), process count + top-RSS via
  `/proc/*/statm` (busybox `ps` has no `--sort`), `systemd-analyze`,
  wakeups window, disk footprint.
- `baselines/0003/guest-profile2.sh` — low-overhead 60 s per-PID CPU /
  voluntary-ctx-switch / write-bytes profiler (single-pass awk, host-side
  python join).
- `baselines/0001/ssh-run.exp` — expect helper for first-contact password
  login; root gets the host key via `sudo -S` on the first login, after which
  everything is BatchMode.

## 5. The seven steps

### 0001 — the strip (1187 → 267 pkgs)

Pin-then-delete: keep-list `apk add` **first** (mesa set incl.
panfrost, pipewire set, alsa set, NM, openssh, bluez, wpa_supplicant, polkit,
dbus-broker, libinput), then one `apk del` cascade over every graphical world
entry (phosh + greetd/phrog + plymouth, firefox-esr, GNOME-mobile apps,
gstreamer, flatpak, cups, fonts, lang/locale 234 MB, ttyescape, fprintd…).
Orphans fell with it: ModemManager, avahi, udisks2, upower, tuned, gnome-
keyring, python3, presage, chrony (timesyncd covers time).

- **Caught regression**: getty `203/EXEC` — `/usr/sbin/agetty` was a GUI-side
  orphan; on Alpine edge agetty is its **own package** (`util-linux-misc`
  does not contain it). `apk add agetty`, pinned. Console login verified.
- Result: 881 MiB image; 107 MiB RAM; 16 services; 28.1 IRQ/s.
- **Trap recorded**: applying the agetty fix while the VM ran *on the
  flattened artifact*, then re-converting from the overlay, clobbered the fix
  — know which file your VM writes; artifacts come only from overlay-convert.

### 0002 — file/config cuts + the blocked-deps map (881 → 754 MiB)

Forensics: parse `/lib/apk/db/installed` `P:`/`I:` sizes; `du -x`; `ldd`;
reverse-deps via awk on `D:` lines; read-only `apk del --simulate` batches.

- Executed: `/boot/dtbs` (**117 MB** — loader entry has no `devicetree`
  line; `-M virt` supplies its own DTB), `/boot/System.map` (11.6 MB),
  `/var/lib/{swcatalog,greetd,geoclue,plymouth,flatpak,udhcpd,xfsprogs}`,
  `userdel greetd geoclue avahi pulse`, caches, journald `SystemMaxUse=10M`,
  `systemctl mask` oomd + coredumpd, `/etc/tuned` leftovers.
- **Blocked at apk level (verified, don't retry)**: `llvm22-libs` (168 MB —
  `libdril_dri.so` links libLLVM; llvmpipe lives in `libgallium`),
  `spirv-tools`←mesa, `nss`←NetworkManager, X11 client stack←mesa/pipewire/
  alsa/base, `cracklib`+`libpwquality`←postmarketos-base, `tpm2-tss`←
  bluez/libinput/NM, `xfsprogs-extra`/`font-terminus`/`util-linux-misc`←base.
  These are **pmaports-track** items.
- **Lessons**: `fstrim -v /` does not cover the vfat ESP (trim `/boot` too:
  872 → 754 MiB); APFS settling after a big convert faked 20 s boots (idle
  the host; the same image did 12.6 s).

### 0003 — hwdb diet (714 MiB)

`/etc/udev/hwdb.bin` 13.5 MB is a compiled trie over 9.5 MB of *name-lookup*
sources; input classification is the hwdb-independent `input_id` builtin.
Dropped 11 vendor-model databases (USB/PCI/OUI/ACPI/BT/DMI/SDIO names,
FireWire, IMDS, fingerprint, TPM); kept all functional `60-*`/`70-*` quirk
sets incl. `autosuspend-chromiumos` (Krane is a ChromeOS device) and the
interface-naming/class dbs. `systemd-hwdb update` → **288 KB**. Verified:
`ID_INPUT_*` intact (KEY/KEYBOARD/MOUSE), eth0 naming, coldplug clean.
**Trap**: `udevadm trigger` returns before the queue drains — verify after a
settle. Runtime unchanged (dormant data): 22.8 IRQ/s, 105 MiB RAM, 12.4×3 s.

### 0004 — runtime tuning (11.4 IRQ/s)

From the runtime profile (0.000 s userland CPU, 0 KB idle writes; the wake
sources were kcompactd, vmstat 1 s, psimon, wpa_supplicant):

```ini
# /etc/sysctl.d/10-alloy-idle.conf
vm.stat_interval = 10
vm.dirty_writeback_centisecs = 6000
```

Loader entry: `transparent_hugepage=madvise` + **`psi=0`** — discovery: PSI
is kernel-default-on; removing pmOS's redundant `psi=1` did nothing, the
explicit `psi=0` was needed (psimon 3→0, `/proc/pressure` gone).
`systemctl disable wpa_supplicant rtkit-daemon` — both re-activate via D-Bus
(`fi.w1.wpa_supplicant1`, `org.freedesktop.RealtimeKit1`) when hardware/
session appears. `apk-inhibit` kept (sleep-inhibitor during apk = real safety
on a tablet). **Trap**: `ps | grep -c X` counts the grep; count via
`/proc/*/comm`. Result: 11.4 IRQ/s (−50 %), 101 MiB RAM, 12 services.

### 0005 — IRQ floor + swap layering (8.73 IRQ/s)

- **Failed A/B (recorded as failed)**: `kernel.watchdog=0` — this build has
  **no such sysctl**; `stat_interval=100` vs 10 — no measurable change.
- **Found**: kcompactd still woke 2.0/s *with* THP=madvise — proactive
  compaction runs on its own timer. `vm.compaction_proactiveness = 0`
  (baked into the drop-in) → arch_timer 9.58→7.25/s.
- **Swap layering**: zram already zstd 5.7 G pri 300 (pmOS unit);
  added `fallocate`d **2 GB `/swapfile`, pri 10** (fstab) as overflow.
  Measured behavior: demand ≤ 3.5 GiB → **no swap** (correct — no pressure);
  3.9 GiB crossing → zram absorbed ~740 MB (zeros are same-filled pages:
  382 MB logical → 200 KB stored); zram disarmed → disk file absorbed
  632 MB, latency flat; 3.6 GiB *incompressible* → **OOM → kernel panic**
  (clean fast-fail + reboot, `panic_on_oom` semantics). Usability probes
  (apk/DNS/SSH latency) flat at 0.26–0.29 s through every state.
- **Gotchas paid for**: `swapoff -a` kills pmOS zram until its unit restarts
  (and it re-arms as the *next free* zram device — monitor `/proc/swaps`,
  never fixed paths); `rm -rf` of a mountpoint breaks the next tmpfs mount
  silently; masked ssh stderr swallows remote errors.

### 0006 — kernel-module diet (692 MiB, 6.92 IRQ/s)

Of 2176 module files (72.8 MB), only a qemu-`virt`-reachable set can ever be
requested by modalias. Critical safety fact: **ext4, vfat, zram, drm,
virtio_blk, virtio_net are builtin**. Mechanical keep-rules (the spec is
`baselines/0006/guest-modprune.sh`): virtio core, USB host/storage/class,
HID+input (uinput/uhid required by `modules-load.d`), tun/wireguard, NVMe,
DRM core+virtio (all vendor DRM dropped), sound core/hda/usb/drivers/virtio
(ASoC/SoC codecs dropped), netfilter/ipv4/ipv6/sched, fuse/overlay/nls,
crypto/arch, scsi root files. Dropped: wireless, ethernet, all vendor DRM,
media, BT/NFC/CAN/WWAN, SoC platform (phy/pinctrl/regulator/power), md,
NFS/CIFS/Btrfs/XFS, raid libs, the unused **vsock trio** and `libcomposite`
(kept loading via initramfs's own copy — harmless).

Aftermath: `depmod -a`, then proof that **every loaded module still resolves**
and the boot/dev set resolves (`tun wireguard snd_hda_intel uinput uhid
hid_multitouch usbnet cdc_ether virtio_gpu sd_mod snd-aloop nft_ct
xt_MASQUERADE`). 2176→625 files, 72.8→23.3 MB. Runtime loads only 7 modules.
`apk audit` deviation accepted + documented (restorable via
`apk fix linux-postmarketos-stable`); real Krane uses its own kernel package
— this defines the QEMU artifact only. Bonus: 6.92 IRQ/s (smaller alias set,
no vsock/rfkill churn).

### 0007 — configuration sweep (the floor)

Audit-then-fix, all upstream drop-ins:

| System | Found | Set |
|---|---|---|
| sshd `AllowTcpForwarding` | **no** (pmOS UI policy) | **yes** — dev tunnels; functionally verified host-side (`ssh -L` → listener answers) |
| sshd | LoginGraceTime 120, no keepalive | 30 s; ClientAlive 60×3 (dead sessions reaped ~3 min instead of hoarding ~10 MB) |
| NetworkManager | connectivity probe unset (NM default on), info logging | probes off, level=WARN |
| resolved | **LLMNR listening :5355 v4+v6** | off (mDNS already off by distro) |
| journald | persistent cap only | + `RuntimeMaxUse=10M` |
| PID1 | 90 s stop timeout | 5 s |
| udevd | unbounded coldplug forks | `children_max=2` |
| sysctl | `watermark_boost_factor=15000` | 0 |
| fstab | `rw,relatime` / and /boot | `noatime` |
| bluetooth.service | enabled (unused) | disabled (bluez kept for Krane) |
| verified-correct, kept | root key-only ssh, UseDNS off, page-cluster 0, zram zstd, empty nftables, tmpfs /tmp, gettys, apk-inhibit | — |

Result: 698 MiB; wakeups/RAM within noise (this sweep is hygiene, not
footprint); 0 failed units; **the only listeners are `:53` (resolved stub)
and `:22` (sshd)**.

## 6. The 0007 floor — what is actually running

**12 services**: apk-inhibit, dbus-broker, getty@tty1, NetworkManager,
serial-getty@ttyAMA0, sshd, systemd-journald, systemd-logind,
systemd-resolved, systemd-timesyncd, systemd-udevd, user@0 (SSH-probe
artifact — absent without a login session). 7 kernel modules loaded
(rfkill, uhid, virtiofs, fuse, hid_generic, evdev, libcomposite-initramfs).
One timer (tmpfiles-clean, daily). Swap: zram0 (zstd, 5.7 G, pri 300) +
/swapfile (2 G, pri 10), 0 B used at idle — by design.

**Config surface added by ALLOY** (all reversible):
`/etc/apk/keys/*` (19), `/etc/ssh/sshd_config.d/00-alloy.conf`,
`/etc/NetworkManager/conf.d/00-alloy.conf`,
`/etc/systemd/resolved.conf.d/00-alloy.conf`,
`/etc/systemd/journald.conf.d/10-alloy-cap.conf`,
`/etc/systemd/system.conf.d/00-alloy.conf`, `/etc/udev/udev.conf`
(children_max), `/etc/sysctl.d/10-alloy-idle.conf` (4 lines), `/etc/fstab`
(noatime + swapfile), `/boot/loader/entries/pmos.conf` (psi=0, THP=madvise),
`systemctl` masks (oomd, coredumpd) and disables (wpa, rtkit, bluetooth),
`/swapfile`, module/hwdb/var/boot file deletions (documented apk-audit
deviations).

**Behavioral profile**: boot 12.5 s to SSH (5.5 s of that is EDK2 firmware;
guest userspace 2.4 s); idle CPU 0.000 s, idle writes 0 B, 7.1 IRQ/s
(arch_timer 5.8/s is the HVF host-scheduling floor — on real Krane this
becomes tickless-kernel behavior); zram+disk swap absorbs compressible spikes
with flat latency; incompressible demand near 100 % of RAM fast-fails
(OOM-panic) instead of thrashing; dev tunnels work; dead SSH sessions reap in
~3 min.

## 7. Cumulative metrics (state by state)

| | Phosh | 0001 | 0002 | 0003 | 0004 | 0005 | 0006 | **0007** |
|---|---|---|---|---|---|---|---|---|
| Image MiB | 2208 | 881 | 754 | 714 | 719 | 734 | 692 | **698** |
| Packages | 1187 | 267 | 267 | 267 | 267 | 267 | 267 | **267** |
| Boot RAM MiB | 183 | 107 | 103 | 105 | 101 | 98 | 105 | **96** |
| Procs | 130 | 105 | 103 | 105 | 99 | 100 | 100 | **100** |
| Services | 27 | 16 | 14 | 14 | 12 | 12 | 12 | **12** |
| Wakeups /s | 114.9 | 28.1 | 23.9 | 22.8 | 11.4 | 8.73 | 6.92 | **7.1** |
| Modules (files/MB) | 2176/72.8 | = | = | = | = | = | 625/23.3 | **=** |
| Boot→SSH s | 12.5 | 12.9–15.9 | 12.6 | 12.4 | 12.4 | 12.4 | 12.4 | **12.5** |

(Image size wobbles ±5 MiB with journal/config churn between compactions;
RAM ±9 MiB is the sample band; boot is firmware-bound throughout.)

## 8. Revert matrix

| Step | Revert |
|---|---|
| 0001 strip | `apk add postmarketos-ui-phosh …` — or reset to the pristine image (backing chain) |
| 0002 cuts | restore from parent artifact |
| 0003 hwdb | restore sources, `systemd-hwdb update` |
| 0004 tuning | `rm /etc/sysctl.d/10-alloy-idle.conf`; restore `psi=1` in loader entry; `systemctl enable --now wpa_supplicant rtkit-daemon` |
| 0005 swap | `swapoff /swapfile && rm /swapfile && sed -i /swapfile/d /etc/fstab`; drop the compaction line |
| 0006 modules | `apk fix linux-postmarketos-stable && depmod -a` — or reset to 0005 artifact |
| 0007 configs | delete the `*-alloy*.conf` drop-ins, `systemctl unmask/enable`, restore fstab options |

## 9. Reproduce (condensed)

```sh
cd ~/Documents/gihhub/Kukui-krane
# state N from parent P:
qemu-img create -f qcow2 -F qcow2 -b <P>.qcow2 baselines/000N/overlay.qcow2
cp baselines/<P>/vars.fd baselines/000N/vars.fd
scripts/run-qemu-headless.sh baselines/000N/overlay.qcow2 \
    baselines/000N/serial.log baselines/000N/qemu.pid 2222 baselines/000N/vars.fd
#   … apply changes (see §5 and the per-step docs) …
#   in guest: fstrim -v / && fstrim -v /boot && poweroff
qemu-img convert -O qcow2 baselines/000N/overlay.qcow2 baselines/000N/alloy-baseline-000N.qcow2
baselines/0001/measure-boot.sh baselines/000N/alloy-baseline-000N.qcow2 \
    baselines/000N/serial-bX.log baselines/000N/timings-bX.txt 2222 baselines/000N/vars.fd
baselines/0001/collect-metrics.sh <prefix> 60     # ≥2 min after boot
```

## 10. Manifest

```
images/pmos-qemu-aarch64.qcow2        ← pristine source (never modified)
baselines/000{1..7}/
    alloy-baseline-000N.qcow2         ← the seven artifacts (each bootable)
    overlay-000N.qcow2, vars.fd       ← isolation + NVRAM
    timings-*.txt, serial-*.log       ← measured boots
    out/                              ← raw metrics, inventories, demos
    guest-*.sh                        ← strip/prune/profile/demo logic
baselines/0001/{measure-boot,collect-metrics,ssh-run,guest-wakeups}.*
scripts/run-qemu-headless.sh
docs/ALLOY-BASELINE-000{1..7}.md      ← per-step records (primary evidence)
docs/ALLOY-PROFILE-0004-RUNTIME.md    ← runtime profile + catalog
docs/ALLOY-PROCEDURE-0001-to-0005.md  ← detailed history through 0005
docs/ALLOY-PACKET-0000-to-0007.md     ← this packet
docs/ALLOY-HISTORY-AND-SACRIFICES.md  ← the narrative: decisions + sacrifice ledger
docs/ALLOY-OPERATIONS.md              ← day-2 manual (boot/change/upgrade/troubleshoot)
docs/ALLOY-GUI-LINEAGE.md             ← graphical lineage + freeze manifests
alloy/README.md                       ← the 0008 build program (Core, profiles, gates)
```

## 11. What's next (queued, each a measured step)

1. **LLVM-free Mesa** (−168 MB): pmaports rebuild — panfrost-only GL without
   llvmpipe; the single biggest remaining disk item.
2. **Initramfs features** (15.3 MB): mkinitfs feature trim, boot-verified.
3. **Tickless/kernel-config work**: <7 IRQ/s needs `nohz_full`/config changes
   (kernel track; on real Krane the timer story changes anyway).
4. **Duranium**: the immutable build starts from exactly this floor.

---
*All measurements 2026-09-08 on Apple M2 / QEMU 11.1.1 / HVF. Every number
above was executed, not extrapolated; every failure is recorded beside the
wins because the traps are part of the provenance.*
