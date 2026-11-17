# ALLOY-BASELINE-0001

**Stripped postmarketOS baseline for the Krane project** — ordinary mutable
postmarketOS, reduced to the agreed keep-list, with every reduction measured.

| | |
|---|---|
| ID | ALLOY-BASELINE-0001 |
| Date | 2026-09-08 |
| Parent | Kukui-Krane ARM lab (Track 2: qemu-aarch64 experiment VM) |
| State | mutable postmarketOS edge (systemd) — *not* Duranium |
| Artifact | `baselines/0001/alloy-baseline-0001.qcow2` (879–881 MiB, qcow2, virtual 4.1 GiB) |
| Login | `user` / `147147` (root key auth pre-provisioned for the lab host) |

---

## 1. Provenance

```
pmbootstrap 3.11.1 (Docker, pmb-kukui-lab)
  └─ qemu-aarch64 / edge / phosh / systemd      ← "ordinary mutable postmarketOS"
      └─ images/pmos-qemu-aarch64.qcow2 (2208 MiB)   pristine, never modified
          └─ baselines/0001/overlay.qcow2            strip performed here (qcow2 overlay)
              └─ baselines/0001/alloy-baseline-0001.qcow2  flattened result (879 MiB)
```

The pristine image is byte-identical to what the lab README documents and can
always be re-derived via the overlay chain above.

## 2. Keep-list (the floor — deliberately conservative)

| Area | Kept |
|---|---|
| Kernel | `device-qemu-aarch64-kernel-stable` (linux-stable 7.2.4) + `postmarketos-mkinitfs` |
| Firmware | `linux-firmware-none` (virt needs no blobs; real Krane will swap in ath10k/MT8183 sets) |
| Mesa/Panfrost | `mesa`, `mesa-dri-gallium` (**`panfrost_dri.so` present**, plus `lima`, `mediatek`, `virtio_gpu`, `swrast`), `mesa-egl`, `mesa-gbm` |
| Init | systemd (full), `dbus-broker`, `polkit` |
| Networking | `networkmanager`, `wpa_supplicant` (Krane WiFi), `systemd-resolved`, `systemd-timesyncd` |
| Audio | `pipewire`, `wireplumber`, `alsa-lib`, `alsa-utils`, `alsa-ucm-conf`, `alsa-plugins-pulse`, `rtkit` (realtime helper) |
| Input | `libinput` (+udev rules), kernel evdev, systemd-udevd |
| SSH/dev | `openssh` (server+client), `sudo-rs`, `apk-tools`, `agetty` (console login), getty@tty1 + serial-getty@ttyAMA0 |
| Mobile plumbing (kept, tiny) | `hkdm` (hardware hotkeys — Krane has volume keys), `routewrangler` (pmOS routing policy) |
| Console font | `font-terminus` |

## 3. What was removed (the measured strip)

One `apk del` cascade over every GUI-world package:

> calls, chatty, decibels, firefox-esr, flatpak, font-droid, font-droid-nonlatin,
> font-twemoji, fprintd, g4music, gnome-calculator, gnome-calendar, gnome-clocks,
> gnome-console, gnome-contacts, gnome-maps, gnome-text-editor, gnome-user-share,
> gnome-weather, gst-libav, gst-plugins-bad, gst-plugins-good, gst-plugins-rs-dav1d,
> gvfs-full, lang, loupe, lpa-gtk, mobile-config-firefox, nautilus, papers,
> phosh-mobile-settings, phosh-tour, postmarketos-tweaks-setting-definitions,
> postmarketos-ui-phosh (→ phosh, greetd-phrog, squeekboard, plymouth, …),
> rygel, showtime, snapshot, ttyescape, tuned-ppd, vvmplayer, cups

Removed *with* the cascade (orphaned deps, verified gone): ModemManager, avahi,
udisks2, upower, tuned, hkdm's UI hooks, gnome-keyring, python3, presage,
chrony (inactive anyway — `systemd-timesyncd` is the time source), all `-lang`
locale packs (234 MB), xfce/gtk portal stack, xdg-user-dirs, etc.

**Fix-ups during the strip (recorded, not blind):**

1. `apk add` pins *before* the cascade so keep-list packages could not be
   orphan-removed (mesa set, pipewire set, alsa set, NM, openssh, bluez,
   wpa_supplicant, polkit, dbus-broker, libinput).
2. `agetty` had to be **re-pinned explicitly** — on current Alpine edge it is
   its own package, was pulled in only as a GUI-side dep, and its absence made
   `getty@tty1` + `serial-getty@ttyAMA0` fail with `203/EXEC` (caught by the
   post-strip boot verification, fixed, re-pinned, re-verified).

## 4. Environment (held fixed for all measurements)

| Component | Value |
|---|---|
| Host | Apple M2, 16 GB, macOS 26.6.1, QEMU 11.1.1 (Homebrew) |
| Accel | `-accel hvf -cpu host` (near-native) |
| Machine | `-M virt,highmem=on`, 4 vCPU, 4096 MiB RAM |
| Devices | virtio-blk (discard=unmap), virtio-net (usermode NAT, hostfwd 127.0.0.1:2222→22), qemu-xhci + usb-kbd + usb-tablet, **no display/GPU device** |
| Firmware | EDK2 AArch64 (brew) pflash + `baselines/0001/vars.fd` |
| Boot mode | headless, serial → `baselines/0001/serial-alloy.log` |
| Kernel cmdline | `console=tty1 console=ttyAMA0,115200 psi=1` (unchanged) |

Scripts: `scripts/run-qemu-headless.sh` (boot), `baselines/0001/measure-boot.sh`
(timed spawn→SSH), `baselines/0001/collect-metrics.sh` (in-guest collection).

## 5. Results

| Metric | Pre-strip (Phosh edge) | **ALLOY-BASELINE-0001** | Δ |
|---|---|---|---|
| Packages installed | 1187 | **267** | −78 % |
| Installed payload | 2081 MB | **632 MB** | −70 % |
| Image size (qcow2 file) | 2208 MiB | **881 MiB** (887 MiB as stripped; 879 MiB after final compact + boot churn) | −60 % |
| Root fs used | 2.0 GB | **671 MB** | −67 % |
| `/usr` | 1799 MB | **447 MB** | −75 % |
| Boot RAM (used, ~2 min after boot) | 183 MiB | **107 MiB** | −41 % |
| MemAvailable (of 3896) | 3430 MiB | **3590 MiB** | +160 MiB |
| Process count | 130 | **105** (≈ 5 are the SSH measurement session; ≈ 100 clean) | −20 % |
| Running systemd services | 27 | **16** | −41 % |
| Boot to SSH (host-measured, spawn→auth OK) | 12.5 s | **12.9–15.9 s** across runs | ≈ unchanged |
| systemd-analyze total | 10.08 s | **9.48–11.72 s** across runs | firmware-dominated |
| systemd userspace | 3.13 s | **2.58–3.77 s** (greetd 1.0 s gone from critical chain) | −0.5 s typical |
| Idle wakeups (60 s window) | 114.9 IRQ/s | **28.1 IRQ/s** | −76 % |

**Idle wakeup breakdown (baseline, 60 s):** `arch_timer` 23.9/s, function-call
IPIs 4.0/s, virtio requests <0.2/s, rescheduling 0.07/s. Pre-strip the same
window showed 73.5/s timer + 37/s function-call — the −76 % comes almost
entirely from removing GUI service timers (tuned, plymouth/greetd churn,
ModemManager polling, avahi).

**Running services (baseline, all 16):** apk-inhibit, dbus-broker, getty@tty1,
NetworkManager, rtkit-daemon, serial-getty@ttyAMA0, sshd, systemd-coredumpd,
systemd-journald, systemd-logind, systemd-oomd, systemd-resolved,
systemd-timesyncd, systemd-udevd, user@0, wpa_supplicant.

**Top RSS (baseline):** NetworkManager 12.9 MB, systemd 12.6 MB,
systemd-journald 10.6 MB, systemd-udevd 9.3 MB — no process above 13 MB.

## 6. Post-strip verification checklist (all pass)

- `systemctl --failed` → 0 units
- NetworkManager / sshd / systemd-resolved / systemd-timesyncd / systemd-udevd / dbus-broker → active
- Serial console (ttyAMA0) and tty1 gettys → active; serial log reaches `login:`
- SSH key + password auth both work; sudo works for `user`
- `apk update` clean (keyring was empty in the source image — refreshed from
  the pmbootstrap chroot keyring; see §8)
- `panfrost_dri.so` present in `/usr/lib/dri/`
- Root fs clean-shutdown, `fstrim -v /` reports ~3 GB discardable (virtio unmap wired through)

## 7. Measurement methodology & caveats

- **Boot RAM** is `free -m` used + MemAvailable, sampled ~2 min after SSH is
  reachable, with zram swap (5844 MB) configured by pmOS and 0 used.
- **Boot time** has two views: host-side spawn→SSH-auth (includes ~5.5 s EDK2
  firmware init) and guest-side `systemd-analyze`. Run-to-run variance under
  HVF is ±1–3 s; comparisons after this point must use the same scripts and
  geometry, and ideally median-of-3.
- **Idle wakeups** = Δ(/proc/interrupts sum) over a 60 s window after a 15 s
  settle, measured *inside* the guest. Under HVF the arch_timer rate partially
  reflects host scheduler behavior — treat as comparative, not absolute.
- **Process count** is inflated by ~5 procs from the measurement SSH session
  itself (sshd-session ×2, pam, sh).
- Collection is deliberately delayed ≥2 min after boot: an earlier attempt that
  started collecting ~30 s post-boot hung in SSH until the guest settled
  (journald flush + first-boot I/O). Only post-settle numbers are recorded.
- The VM has no RTC battery; clock is set at boot (timesyncd active). TLS-heavy
  operations before first sync may complain.

## 8. Known deviations / debts (queued, each to be measured when tackled)

1. `wpa_supplicant` runs with no WiFi device in QEMU (kept for Krane parity;
   candidate for a measured −1 service in the QEMU profile only).
2. `systemd-coredumpd` / `systemd-oomd` / `rtkit` are systemd/pipewire defaults
   — candidates for measured removal if the Duranium profile allows.
3. `bluetooth.service` is installed-but-inactive (bluez kept for Krane BT audio/input).
4. `chrony` was removed with the cascade; `systemd-timesyncd` covers time sync.
5. `/boot` ESP still carries the full DTB set and System.map from the image build.
6. Kernel modules: 72 MB — no per-driver pruning attempted (kernel is keep-list).
7. The image's apk keyring was empty at handoff; refreshed from the pmbootstrap
   container. Any future rebuild from pmaports should ensure keys ship in-image.

## 9. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane

# boot the baseline artifact
./scripts/run-qemu-headless.sh baselines/0001/alloy-baseline-0001.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0001/vars.fd

# timed boot + metrics (see files in baselines/0001/)
baselines/0001/measure-boot.sh baselines/0001/alloy-baseline-0001.qcow2 \
    baselines/0001/serial-alloy.log baselines/0001/timings-alloy.txt 2222 \
    baselines/0001/vars.fd
baselines/0001/collect-metrics.sh <prefix> 60     # ≥2 min after boot
```

Artifacts in `baselines/0001/`: `alloy-baseline-0001.qcow2`, `overlay.qcow2`
(throwaway), `vars.fd`, `timings-pre.txt`, `timings-alloy.txt`,
`serial-pre.log`, `serial-alloy.log`, `guest-wakeups.sh`, `collect-metrics.sh`,
`measure-boot.sh`, `ssh-run.exp`, and `out/` with:
`world-before.txt`, `packages-before.txt`, `pkgnames-before.txt`,
`strip-log.txt`, and `prestrip.*` / `baseline-0001.*` metric files.

---
*Everything above was executed and measured on 2026-09-08. No number here is
extrapolated. Next reductions must land as ALLOY-BASELINE-0002+ with the same
geometry and the same scripts.*
