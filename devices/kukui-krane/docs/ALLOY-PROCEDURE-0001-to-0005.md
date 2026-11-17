# ALLOY procedure: from postmarketOS Phosh image to ALLOY-BASELINE-0005

The complete, chronological record of how the stripped baseline was built —
every command that mattered, every measured result, every failed experiment
and trap. Read together with the per-step records
(`ALLOY-BASELINE-000{1..5}.md`) and the runtime profile
(`ALLOY-PROFILE-0004-RUNTIME.md`).

**Ground rules that held for the whole journey:**

1. **The pristine image is never written.** Every state is a qcow2 overlay
   backed by the previous artifact; the final artifact is a *flattened
   convert* of the overlay. Backing chain: Phosh image → 0001 → 0002 → 0003 →
   0004 → 0005.
2. **Every reduction is measured** with the same harness and the same fixed VM
   geometry; failed experiments are recorded as failed.
3. **Everything stays upstream**: `apk del/add`, sysctls, kernel cmdline,
   systemd drop-ins, `systemctl disable/mask`, file removals + regenerations.
   No patches, no forks, no custom packages.

---

## 0. Starting point

| | |
|---|---|
| Host | Apple M2, 16 GB, macOS 26.6.1, QEMU 11.1.1 (Homebrew), EDK2 AArch64 firmware |
| Source image | `images/pmos-qemu-aarch64.qcow2` — 2208 MiB, built by pmbootstrap 3.11.1 in Docker (`pmb-kukui-lab`), device `qemu-aarch64`, channel **edge (systemd)**, UI **Phosh**, manual disk assembly (lab README §12) |
| Credentials | `user` / `147147` (console + SSH + sudo) |
| Boot | EDK2 pflash + NVRAM vars → systemd-boot → pmOS initramfs → systemd |

Fixed measurement geometry for every run in this document (held constant so
numbers stay comparable):

```
-M virt,highmem=on  -accel hvf  -cpu host  -smp 4  -m 4096
virtio-blk (discard=unmap), virtio-net (usermode NAT, hostfwd 127.0.0.1:2222→22)
qemu-xhci + usb-kbd + usb-tablet, no display device, headless
serial → socket chardev with logfile (baselines/<step>/serial-*.log)
```

## 1. Groundwork (before any strip)

**Isolation.** `baselines/0001/` with a qcow2 overlay over the pristine image
plus a copy of the UEFI NVRAM vars:

```sh
qemu-img create -f qcow2 -F qcow2 \
    -b "$PWD/images/pmos-qemu-aarch64.qcow2" baselines/0001/overlay.qcow2
cp images/firmware/vars-pmos.fd baselines/0001/vars.fd
scripts/run-qemu-headless.sh baselines/0001/overlay.qcow2 \
    baselines/0001/serial-boot.log baselines/0001/qemu.pid 2222 baselines/0001/vars.fd
```

**SSH automation** (no sshpass on macOS): `/usr/bin/expect` for the first
password login (`baselines/0001/ssh-run.exp`), then install the host key for
`user` and (via `sudo -S` fed through stdin) for `root`:

```sh
ssh user@… "printf '147147\n' | sudo -S -p '' sh -c \
  'mkdir -p /root/.ssh && cp /home/user/.ssh/authorized_keys /root/.ssh/ && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys'"
```

All later access is `ssh -o BatchMode=yes root@127.0.0.1 -p 2222`.

**Measurement harness** (`baselines/0001/`):

- `measure-boot.sh` — python3 `t0` before QEMU spawn → poll BatchMode-SSH
  until auth succeeds → `t1`; writes `boot_seconds`.
- `collect-metrics.sh` — system context, `free`/`/proc/meminfo`/dmesg, process
  count via `/proc/[0-9]*` + top-RSS via `statm` (busybox `ps` has no
  `--sort`), `systemd-analyze`, idle-wakeup window (60 s after 15 s settle:
  `/proc/interrupts` + `/proc/stat` deltas, busybox-awk), disk footprint.
- `guest-wakeups.sh` — the guest side of the wakeup window.

**First-boot findings (both fixed):**

- The image shipped an **empty `/etc/apk/keys`** → every repo read as
  UNTRUSTED. Fix: copied the 19-key ring (Alpine + pmOS) out of the pmbootstrap
  chroot: `docker exec pmb-kukui-lab tar cf - -C …/chroot_native/etc/apk/keys .`
  → untar on host → `scp` → `apk update` clean.
- README claimed the root fs was ~3.5 GiB used; reality was **2.0 GB of a
  3686 MiB partition (1.3 G free)**. Trust `df`, not docs.

**Pre-strip reference numbers** (from the pristine Phosh image): 1187
packages / 2081 MB payload; boot→SSH 12.5 s (guest total 10.08 s); boot RAM
183 MiB; 130 processes; 27 running services; idle 114.9 IRQ/s.

## 2. ALLOY-BASELINE-0001 — the strip

**Principle: pin the keep-list into world *before* deleting, so the removal
cascade cannot orphan it.**

```sh
apk add mesa mesa-dri-gallium mesa-egl mesa-gbm pipewire wireplumber \
    alsa-lib alsa-utils alsa-ucm-conf alsa-plugins-pulse libinput \
    networkmanager openssh bluez wpa_supplicant polkit dbus-broker
```

Then one measured cascade over every graphical/GUI world entry:

```sh
apk del calls chatty decibels firefox-esr flatpak font-droid \
    font-droid-nonlatin font-twemoji fprintd g4music gnome-calculator \
    gnome-calendar gnome-clocks gnome-console gnome-contacts gnome-maps \
    gnome-text-editor gnome-user-share gnome-weather gst-libav \
    gst-plugins-bad gst-plugins-good gst-plugins-rs-dav1d gvfs-full lang \
    loupe lpa-gtk mobile-config-firefox nautilus papers phosh-mobile-settings \
    phosh-tour postmarketos-tweaks-setting-definitions postmarketos-ui-phosh \
    rygel showtime snapshot ttyescape tuned-ppd vvmplayer cups
```

Cascade results: **1187 → 266 packages, 2081 → 632 MB payload.** Orphaned and
gone with it: ModemManager, avahi, udisks2, upower, tuned(+ppd), gnome-keyring,
python3, presage, all `-lang` locale packs (234 MB), greetd/phrog, plymouth,
chrony (inactive anyway — `systemd-timesyncd` is the time source).

**Keep-list verified after the cascade**: kernel 7.2.4 +
`postmarketos-mkinitfs`, `linux-firmware-none` (virt needs no blobs), Mesa
with `panfrost_dri.so` present (also `mediatek`, `lima`, `virtio_gpu`,
`swrast`), PipeWire/WirePlumber/ALSA, libinput, NM, OpenSSH, bluez,
wpa_supplicant, polkit, dbus-broker, systemd, sudo-rs.

**Regression caught by post-strip boot verification**: both getty units failed
with `203/EXEC` — `/usr/sbin/agetty` had been a GUI-side orphan. On current
Alpine edge agetty is **its own package** (`util-linux-misc` does *not*
contain it; installing that was a no-op). Fix + pin:

```sh
apk add agetty        # 266 → 267 packages
```

Console login survives without greetd (`getty@tty1` + `serial-getty@ttyAMA0`
enabled by default). Then: `journalctl --vacuum-size=10M`, `fstrim -v /`
(busybox has no `-a`), poweroff, and flatten:

```sh
qemu-img convert -O qcow2 overlay.qcow2 alloy-baseline-0001.qcow2   # 881 MiB
```

**0001 metrics**: 12.9–15.9 s boot (guest 9.48–11.72 s, firmware 5.5 s
dominant); 107 MiB boot RAM; 105 processes; 16 services; **28.1 IRQ/s** idle;
267 pkgs / 632 MB.

**Sequencing trap (recorded, then avoided forever after):** the first agetty
fix was applied while the VM was already running *on the flattened 0001
artifact*, and the subsequent `convert overlay → alloy` clobbered it. Rule:
always know which file your VM writes; fixes land in the overlay, artifacts
are only ever produced by convert-from-overlay.

## 3. ALLOY-BASELINE-0002 — file/config cuts + the blocked-deps map

**Forensics first** (parse `/lib/apk/db/installed` `P:`/`I:` fields; `du -x`;
`ldd`; reverse-dep scan via awk over `D:` lines; `apk del --simulate` batches):

- Biggest items: `linux-postmarketos-stable` 207.5 MB, `llvm22-libs` 167.8 MB,
  `mesa` 35.7 MB. `/usr/lib`: libLLVM 167 MB, kernel modules 72 MB,
  libgallium 36 MB; `/usr/lib/dri` = 61 tiny shims (`libdril_dri.so` 130 KB,
  **links libLLVM** → LLVM is load-bearing via llvmpipe inside libgallium).
- `/boot/dtbs` **117 MB** (42 vendor families), `System.map` 11.6 MB — unused
  on `-M virt` (loader entry has **no `devicetree` line**; QEMU supplies its
  own DTB).
- `/var/lib/greetd` 10.3 MB (a full GNOME-flavored user home), `/var/lib/swcatalog`
  11.3 MB (AppStream for the removed GNOME Software), journal 19 MB,
  `/etc/udev/hwdb.bin` 13.5 MB, caches ~8 MB.

**Blocked at the apk level — verified by `apk del --simulate` (read-only):**
`spirv-tools` ← mesa; `nss` ← NetworkManager; X11 client stack
(`libx11/libxcb/libxau/libxdmcp/xkeyboard-config`) ← mesa/pipewire/alsa/base;
`cracklib-words`+`libpwquality` ← postmarketos-base; `tpm2-tss-*` ←
bluez/libinput/NM chain; `xfsprogs-extra`, `font-terminus`,
`util-linux-misc` ← base/device. `wpa+bluez+rtkit` sim = clean −10 MB
(deferred as a profile decision; handled in 0004).

**Executed cuts** (in the 0002 overlay):

```sh
rm -rf /boot/dtbs && rm -f /boot/System.map            # −128.8 MB on ESP
rm -rf /var/lib/{swcatalog,greetd,geoclue,plymouth,flatpak,udhcpd,xfsprogs}
userdel greetd geoclue avahi pulse                      # stale accounts
rm -rf /var/cache/{apk,distfiles,misc,swcatalog}/* /var/cache/fontconfig/*
printf "[Journal]\nSystemMaxUse=10M\n" > /etc/systemd/journald.conf.d/10-alloy-cap.conf
journalctl --vacuum-size=10M
systemctl mask systemd-oomd.service systemd-oomd.socket \
    systemd-coredump.socket systemd-coredumpd.service systemd-coredump-register.service
rm -rf /etc/tuned /var/log/tuned
```

**Compaction lesson:** `fstrim -v /` does **not** cover the vfat ESP → first
compact still 872 MiB. `fstrim -v /boot` deallocated ~477 MB → **754 MiB**.
Trim *every* filesystem before converting.

**Timing lesson:** two boots measured 20–21 s while APFS was settling after
the 754 MB convert; the identical image measured **12.6 s** on an idle host.
Methodology since: idle the host ≥30 s before timed boots; collect ≥2 min
after boot (an earlier collector hung racing first-boot journald flush).

**0002 metrics**: 754 MiB; 103 MiB RAM; 103 procs; 14 services; 23.9 IRQ/s;
12.6 s / 9.34 s. Packages unchanged (267) — by design, all cuts were
file/config-level.

## 4. ALLOY-BASELINE-0003 — the hwdb diet

`/etc/udev/hwdb.bin` (13.5 MB compiled trie) is built from
`/usr/lib/udev/hwdb.d/` (9.5 MB, 40 files). The mass is *name-lookup* data —
nothing on a headless system reads it. Input classification is udev's
`input_id` **builtin** and hwdb-independent.

Dropped (11 files, 9.1 MB): `20-{OUI,acpi-vendor,bluetooth-vendor-product,
dmi-id,sdio-vendor-model,pci-vendor-model,usb-vendor-model}.hwdb`,
`80-ieee1394-unit-function.hwdb`, `40-imds.hwdb`,
`60-autosuspend-fingerprint-reader.hwdb`, `60-tpm2.hwdb`.

Kept (~380 KB): all functional `60-*` (`evdev`, `input-id`, `keyboard`,
`seat`, `sensor`, `autosuspend`, **`autosuspend-chromiumos`** — Krane is a
ChromeOS device), all `70-*`, class + interface-naming dbs
(`20-{pci,usb,sdio}-classes`, `20-vmbus-class`, `20-net-ifname`,
`82-net-auto-link-local`).

```sh
rm -f /usr/lib/udev/hwdb.d/20-{OUI,acpi-vendor,…}.hwdb   # the 11 files
systemd-hwdb update                                       # 13516 → 288 KB
systemctl restart systemd-udevd && udevadm control --reload && udevadm trigger
```

Verification: `ID_INPUT_*` intact on all event devices (KEY / KEYBOARD /
`MOUSE` for the usb-tablet), `eth0` naming intact, 0 failed units.

**Race recorded:** `udevadm info` queried ~3 s after `udevadm trigger`
returned empty properties; the same query after settling was correct.
`udevadm trigger` returns before the event queue drains — always verify after
a settle.

**0003 metrics**: 714 MiB; 105 MiB RAM; **12.4 / 12.4 / 12.4 s** boots
(median-of-3 introduced); 22.8 IRQ/s; 9.28 s guest. A pure disk win — runtime
unchanged within noise, exactly right for a dormant-database cut.

## 5. Runtime profile (basis for 0004)

`baselines/0003/guest-profile.sh` + the low-overhead
`guest-profile2.sh` (single-pass awk over `/proc/[0-9]*/{stat,status,io}`,
host-side python join) over a 60 s idle window:

- **Userland CPU 0.000 s across all 95 processes; disk writes 0 KB.**
- 25.0 IRQ/s: arch_timer 19.1/s (HVF floor), IPIs 3.4/s, virtio <0.3/s.
- Wakeup attribution: **kcompactd 2.0/s** (THP was `[always]`, khugepaged
  scanning every 10 s), kworkers 4.3/s (`vm.stat_interval=1`), **psimon ×5
  0.4/s** (`psi=1` cmdline; oomd already masked), wpa_supplicant 0.1/s,
  everything else ≤1 per 60 s.
- Effective config: `stat_interval=1`, `dirty_writeback=500`, THP `always`,
  `psi=1`, swappiness 180 (pmOS zram default, kept).

Full analysis and catalog: `docs/ALLOY-PROFILE-0004-RUNTIME.md`.

## 6. ALLOY-BASELINE-0004 — runtime tuning (config only)

```sh
printf "vm.stat_interval = 10\nvm.dirty_writeback_centisecs = 6000\n" \
    > /etc/sysctl.d/10-alloy-idle.conf
# loader entry (edit, not fork):
sed -i "s/^options .*/options console=tty1 console=ttyAMA0,115200 transparent_hugepage=madvise/" \
    /boot/loader/entries/pmos.conf
systemctl disable wpa_supplicant.service rtkit-daemon.service
```

- **PSI discovery**: removing `psi=1` changed nothing — this kernel has PSI
  *enabled by default*; `/proc/pressure` persisted and 3 psimon monitors kept
  running. Explicit **`psi=0`** in the cmdline is the only working off switch.
- THP `madvise` stops the khugepaged 10 s scan / compaction churn.
- wpa_supplicant and rtkit stay *functionally* available: NM and pipewire
  re-activate them via D-Bus (`fi.w1.wpa_supplicant1`,
  `org.freedesktop.RealtimeKit1` — activation files verified) when the
  hardware/session appears. Krane WiFi/BT and audio unaffected.
- `apk-inhibit` investigated: triggered by `apk-inhibit.path`, holds a sleep
  inhibitor during apk transactions — **kept** (real safety on a suspendable
  device, 1 MiB).
- Trap: `ps | grep -c psimon` counts the grep itself — count via
  `/proc/*/comm`.

**0004 metrics**: **11.4 IRQ/s** (−50 %); 101 MiB RAM; 99 procs; 12 services;
719 MiB image; 12.4/12.4/12.5 s boots; 9.29 s guest. Every piece reversible:
rm the drop-in, restore the options line, `systemctl enable --now`.

## 7. ALLOY-BASELINE-0005 — IRQ floor + swap layering

**IRQ diet — what failed first (recorded as failed):**

- `kernel.watchdog=0` + `vm.stat_interval=100` A/B: **no measurable change**
  (10.7 → 11.7/s, noise). Root cause: this build has **no
  `/proc/sys/kernel/watchdog`** at all. Both ideas dropped.
- Per-PID profile then showed the real remaining waker: **kcompactd still
  2.0/s even with THP=madvise** — *proactive* compaction
  (`vm.compaction_proactiveness=20`) runs on its own timer. Fix:

```sh
sysctl -w vm.compaction_proactiveness=0     # live A/B: 11.4 → 9.57/s window
printf "vm.stat_interval = 10\nvm.dirty_writeback_centisecs = 6000\nvm.compaction_proactiveness = 0\n" \
    > /etc/sysctl.d/10-alloy-idle.conf      # bake in
```

**Swap layering** (zram audit first: algorithm already **zstd**, 5.7 GiB,
priority 300, armed by `postmarketos-zram-swap.service` → `/usr/bin/zramstart`):

```sh
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
swapon /swapfile        # zram pri 300 stays primary
```

**Offload behavior measured (three demo iterations, two instructive failures):**

| Demand (tmpfs on 3.9 GiB RAM) | Result |
|---|---|
| ≤ 3.5 GiB | **No swap** — demand never crossed the watermark (avail dipped to 39 MiB, kswapd never fired). Idle offload is ~0 *by design*. |
| 3.9 GiB (crossing supply) | kswapd evicted ~740 MB → **zram absorbed it**: 382 MB logical → 200 KB stored (zeros are same-filled pages). Latency flat. |
| 3.9 GiB, zram accidentally disarmed | the **disk file** absorbed 632 MB, latency flat — fallback proven. |
| 3.6 GiB *incompressible* (urandom) | **OOM → kernel panic** (`panic_on_oom`: trace `panic ← out_of_memory ← kernel_clone`), clean fast-fail, rebooted healthy in ~2 min. |

**Gotchas paid for in this phase (all documented in the record):**

1. `swapoff -a` kills zram (pmOS arms it via unit, not fstab); the unit
   re-arms as the *next free zram device* (`zram0` → `zram1`) — monitor via
   `/proc/swaps`, never fixed device paths.
2. `rm -rf` on a mountpoint deletes the directory → the next tmpfs mount
   fails and, with stderr masked, writes fail *silently* (one wasted run; the
   mm_stat-vs-/proc/swaps "contradiction" was really a stale/renumbered zram
   device + same-filled-page semantics).
3. `ps | grep -c X` counts the grep.
4. `2>/dev/null` on the ssh client also hides remote errors.

**0005 metrics**: **8.73 IRQ/s** (arch_timer 7.25, IPI 0.97); 98 MiB boot RAM;
100 procs; 12 services; 734 MiB image (+15 for the swapfile + churn); boots
12.4/12.4/12.5 s; 9.29 s guest; 0 failed units; swap layering verified on
fresh boot (zram0 zstd 5.7 G pri 300 + `/swapfile` pri 10, 0 B used at idle).

## 8. Cumulative metrics

| | Phosh img | 0001 | 0002 | 0003 | 0004 | **0005** |
|---|---|---|---|---|---|---|
| Packages | 1187 | 267 | 267 | 267 | 267 | 267 |
| Payload | 2081 MB | 632 MB | 632 MB | 632 MB | 632 MB | 632 MB |
| Image (qcow2) | 2208 MiB | 881 | 754 | 714 | 719 | **734** (incl. 2 GB swapfile, sparse) |
| Boot RAM | 183 MiB | 107 | 103 | 105 | 101 | **98** |
| Processes | 130 | 105 | 103 | 105 | 99 | **100** |
| Services | 27 | 16 | 14 | 14 | 12 | **12** |
| Idle wakeups | 114.9/s | 28.1 | 23.9 | 22.8 | 11.4 | **8.73** |
| Boot → SSH | 12.5 s | 12.9–15.9 | 12.6 | 12.4 | 12.4 | **12.4** |
| Guest boot total | 10.08 s | 9.48–11.72 | 9.34 | 9.28 | 9.29 | **9.29** |

(Boot time is firmware-dominated — the 5.5 s EDK2 stage; userspace fell
3.13 → 2.4 s across the steps. A lab-only direct-kernel boot mode could skip
the firmware stage but is documented as not-comparable and not a device claim.)

## 9. Reverting anything

| Step | Revert |
|---|---|
| 0001 strip | re-add packages (`apk add postmarketos-ui-phosh …`); the pristine image is the true reset |
| 0002 file cuts | restore from the parent artifact (backing chain) |
| 0003 hwdb | restore kept+dropped sources, `systemd-hwdb update` |
| 0004 tuning | `rm /etc/sysctl.d/10-alloy-idle.conf`; restore `psi=1` in loader entry; `systemctl enable --now wpa_supplicant rtkit-daemon` |
| 0005 | `swapoff /swapfile && rm /swapfile && sed -i /swapfile/d /etc/fstab`; remove the `compaction_proactiveness` line |

## 10. Full reproduction sequence (condensed)

```sh
cd ~/Documents/gihhub/Kukui-krane
# per state N: overlay from parent, boot, apply changes, verify, trim BOTH fs,
# poweroff, convert, median-of-3 timed boots, collect ≥2 min post-boot
qemu-img create -f qcow2 -F qcow2 -b <parent>.qcow2 baselines/000N/overlay.qcow2
cp baselines/<parent>/vars.fd baselines/000N/vars.fd
scripts/run-qemu-headless.sh baselines/000N/overlay.qcow2 \
    baselines/000N/serial.log baselines/000N/qemu.pid 2222 baselines/000N/vars.fd
# … changes …
# in guest: fstrim -v / && fstrim -v /boot && poweroff
qemu-img convert -O qcow2 baselines/000N/overlay.qcow2 baselines/000N/alloy-baseline-000N.qcow2
baselines/0001/measure-boot.sh baselines/000N/alloy-baseline-000N.qcow2 \
    baselines/000N/serial-bX.log baselines/000N/timings-bX.txt 2222 baselines/000N/vars.fd
baselines/0001/collect-metrics.sh <prefix> 60
```

All scripts live in `scripts/` (run-qemu-headless.sh) and
`baselines/0001/`–`baselines/0005/` (measure-boot.sh, collect-metrics.sh,
guest-wakeups.sh, guest-profile*.sh, guest-ab.sh, guest-offload-demo*.sh,
ssh-run.exp), raw outputs in `baselines/*/out/`.

---
*Executed and measured 2026-09-08. Nothing in this document is extrapolated:
the failed experiments and traps are recorded alongside the wins because they
are part of the state's provenance.*
