# Kukui-Krane ARM Lab

**postmarketOS as close to the Lenovo IdeaPad Duet ("Krane") as QEMU allows — built, booted, and verified on Apple Silicon.**

Status: **WORKING** — the experiment VM boots to a Phosh desktop, SSH, and a full
systemd userspace. This README documents the entire project: the research behind
it, the architecture, exactly what works and what cannot, every known issue and
workaround, the full build pipeline with all its gotchas, and troubleshooting.

> **ALLOY track** — the complete record lives in one place:
> [`docs/ALLOY-PACKET-0000-to-0007.md`](docs/ALLOY-PACKET-0000-to-0007.md)
> (self-contained: provenance, all seven measured steps, final floor, revert
> matrix, reproduction). Quick chain:
> [`docs/ALLOY-BASELINE-0001.md`](docs/ALLOY-BASELINE-0001.md) (267 pkgs, 881 MiB,
> 107 MiB boot RAM, 16 services, 28 IRQ/s) →
> [`docs/ALLOY-BASELINE-0002.md`](docs/ALLOY-BASELINE-0002.md) (754 MiB, boot-file/var
> cleanup + blocked-deps analysis) →
> [`docs/ALLOY-BASELINE-0003.md`](docs/ALLOY-BASELINE-0003.md) (714 MiB, hwdb diet) →
> [`docs/ALLOY-BASELINE-0004.md`](docs/ALLOY-BASELINE-0004.md) (719 MiB, 101 MiB RAM,
> 12 services, 11.4 IRQ/s, runtime tuning) →
> [`docs/ALLOY-BASELINE-0005.md`](docs/ALLOY-BASELINE-0005.md) (**734 MiB**, 98 MiB RAM,
> **8.73 IRQ/s**, zram(zstd)+disk-swap layering with measured offload/OOM-panic
> behavior) →
> [`docs/ALLOY-BASELINE-0006.md`](docs/ALLOY-BASELINE-0006.md) (**692 MiB**, **6.92 IRQ/s**,
> kernel-module diet: 2176 → 625 files, 72.8 → 23.3 MB) →
> [`docs/ALLOY-BASELINE-0007.md`](docs/ALLOY-BASELINE-0007.md) (**698 MiB**, config sweep:
> dev tunnels on, LLMNR/probes off, journal+session hygiene). **ALLOY-0008 program**:
> CORE frozen (sha256+immutable), graphical lineage formalized (`ALLOY-GUI-0000`),
> reproducible Core build + dev/prod/lab profiles in `alloy/`, both gated by
> `alloy/regression-test.sh` + `alloy/quiescence-test.sh` — see
> [`alloy/README.md`](alloy/README.md) and
> [`docs/ALLOY-GUI-LINEAGE.md`](docs/ALLOY-GUI-LINEAGE.md). Narrative + tradeoffs:
> [`docs/ALLOY-HISTORY-AND-SACRIFICES.md`](docs/ALLOY-HISTORY-AND-SACRIFICES.md).
> Day-2 ops: [`docs/ALLOY-OPERATIONS.md`](docs/ALLOY-OPERATIONS.md). Full build record:
> [`docs/ALLOY-PROCEDURE-0001-to-0005.md`](docs/ALLOY-PROCEDURE-0001-to-0005.md).
> Profile + rationale:
> [`docs/ALLOY-PROFILE-0004-RUNTIME.md`](docs/ALLOY-PROFILE-0004-RUNTIME.md).
> Artifacts + scripts: `baselines/0001/` … `baselines/0005/`.

---

## Table of contents

1. [What is Krane?](#1-what-is-krane)
2. [The problem this lab solves](#2-the-problem-this-lab-solves)
3. [Architecture: two tracks](#3-architecture-two-tracks)
4. [What's in this repo](#4-whats-in-this-repo)
5. [Quick start](#5-quick-start)
6. [VM specification](#6-vm-specification)
7. [Hardware mapping: Krane → QEMU](#7-hardware-mapping-krane--qemu)
8. [What the VM CAN do](#8-what-the-vm-can-do)
9. [What the VM CANNOT do](#9-what-the-vm-cannot-do)
10. [Known issues](#10-known-issues)
11. [Troubleshooting cookbook](#11-troubleshooting-cookbook)
12. [Build pipeline: how the image was made](#12-build-pipeline-how-the-image-was-made)
13. [Rebuilding from scratch, step by step](#13-rebuilding-from-scratch-step-by-step)
14. [Disk layout reference](#14-disk-layout-reference)
15. [The real-hardware track (flashing an actual Duet)](#15-the-real-hardware-track)
16. [FAQ](#16-faq)
17. [Verification record](#17-verification-record)
18. [Sources](#18-sources)

---

## 1. What is Krane?

**Krane is the Lenovo IdeaPad Duet Chromebook** (10.1" 1920×1200 detachable
2-in-1 tablet), and the codename of its board in the ChromeOS project. It
belongs to the **Kukui baseboard family** (Google), built on the
**MediaTek MT8183** SoC (marketed as Kompanio 500 in this generation).

Key facts, all verified from primary sources during this project:

| Fact | Value |
|---|---|
| Device tree | `arch/arm64/boot/dts/mediatek/mt8183-kukui-krane-sku176.dts` (mainline Linux) |
| Compatible string | `google,krane-sku176`, `google,krane`, `mediatek,mt8183` |
| SoC | MT8183: 4× Cortex-A73 @ 2.0 GHz + 4× Cortex-A53 @ 2.0 GHz (big.LITTLE) |
| GPU | ARM Mali-G72 MP3 (Panfrost driver: OpenGL ES 3.1 / OpenGL 3.1) |
| RAM / storage | 4 GB LPDDR4X / 64–128 GB eMMC |
| Wireless | Qualcomm Atheros QCA6174A WiFi+BT (ath10k, calibration variant `LE_Krane`) |
| Audio | MediaTek MT6358 PMIC codec |
| Touch | HID-over-I2C touchscreen + USI stylus; "Hammer" USB touchpad/keyboard base |
| Boot chain | Coreboot → **Depthcharge** (ChromeOS bootloader), kernel in `vmlinuz.kpart` |
| postmarketOS port | `google-kukui` device package (covers krane/kukui/kodama/juniper/katsu/kakadu/…), maintainer WeirdTreeThing, **community** category |
| pmOS kernel | `linux-postmarketos-mediatek-mt8183`, 6.12.87 at image build time |
| ChromeOS updates | EOL (stable 145.0.7632.154 was final) |

The SKU number encodes panel + variant (sku176 = 0xb0: BOE panel, SKU 0).
The mainline device-tree family (`mt8183-kukui-krane.dtsi`) shows the panel
regulators, touch controller at I2C0 address 0x5d, and the QCA WiFi node with
the `LE_Krane` ath10k calibration variant.

## 2. The problem this lab solves

You want to experiment with Krane's operating-system environment (postmarketOS,
Phosh, aarch64 userland) **on your Mac, without the physical device**.

The catch: **QEMU has no MT8183/Krane machine model.**
`qemu-system-aarch64 -M help` lists `virt`, `sbsa-ref`, NXP EVKs, Aspeed BMCs… —
nothing MediaTek. That means:

- The **official Krane image will not boot** in any QEMU machine — it expects
  Depthcharge, the MT8183 boot chain, and Krane hardware in its device tree.
- The closest legal target is QEMU's generic **`virt`** machine: a GIC-500
  virtual platform with virtio devices — the standard pmOS `qemu-aarch64` device.

So this lab keeps **both**:

- the *real* Krane image (for analysis + eventual flashing), and
- a *Krane-like* VM that preserves what QEMU actually can preserve: the
  architecture, the distro, the release channel, the UI stack, and the
  workflow — while substituting emulatable devices (virtio) for un-emulatable
  silicon (Mali, ath10k, MT6358, Depthcharge).

## 3. Architecture: two tracks

```
┌─────────────────────────────┐      ┌──────────────────────────────────────┐
│  TRACK 1 — REAL HARDWARE    │      │  TRACK 2 — EXPERIMENT VM (this lab)  │
│  google-kukui image         │      │  qemu-aarch64 image (built here)     │
│                             │      │                                      │
│  postmarketOS v25.12 Phosh  │      │  postmarketOS edge  Phosh  systemd   │
│  linux-mt8183 6.12.87       │      │  linux-stable 7.2.4 (virt kernel)    │
│  Depthcharge + Krane DTB    │      │  EDK2 UEFI + systemd-boot + virt DTB │
│  Mali-G72/Panfrost, ath10k  │      │  virtio-gpu, virtio-net (NAT)        │
│  → flash to a real Duet     │      │  → run on your Mac (HVF, near-native)│
└─────────────────────────────┘      └──────────────────────────────────────┘
```

**Track 1** keeps the official `google-kukui` image on disk (`images/krane-kukui.img`),
checksum-verified and dissected (see §17). Use it for analysis, or flash it to a
physical Duet (§15).

**Track 2** is the VM this project built from source with pmbootstrap, configured
to mirror Krane as closely as the `virt` machine permits: same `aarch64` arch,
same Phosh UI, same systemd service manager, same postmarketOS ecosystem and
workflows, at near-native speed via **HVF** (Apple's hypervisor framework).

## 4. What's in this repo

```
Kukui-krane/
├── README.md                      ← you are here
├── docs/
│   ├── KRANE_SPECS.md             Krane hardware → QEMU mapping table
│   ├── QEMU_VS_KRANE.md           verified comparison, what transfers / what doesn't
│   ├── ALLOY-PACKET-0000-to-0007.md  ★ THE packet: everything, baseline → 0007
│   ├── ALLOY-BASELINE-0001.md     stripped mutable-pmOS baseline, measured
│   ├── ALLOY-BASELINE-000{2..5}.md  measured reductions (754 → 734 MiB, 8.73 IRQ/s)
│   ├── ALLOY-BASELINE-000{6,7}.md   module diet (692 MiB) + config sweep (698 MiB)
│   ├── ALLOY-PROCEDURE-0001-to-0005.md  detailed history through 0005
│   └── ALLOY-PROFILE-0004-RUNTIME.md  runtime profile + optimization catalog
├── scripts/
│   ├── run-pmos-vm.sh             ★ START HERE — boot the VM (gui | headless | serial)
│   ├── run-qemu-headless.sh       daemonized headless boot for measured runs
│   ├── download-kukui.sh          fetch official google-kukui image + verify sha256
│   ├── get-edk2.sh                verify brew's bundled EDK2 AArch64 firmware
│   ├── pmbootstrap-docker.sh      full rebuild pipeline (setup | fixup | shell)
│   └── run-qemu-arm.sh            older generic helper (superseded by run-pmos-vm.sh)
├── alloy/                         ★ ALLOY-0008 program: frozen CORE, reproducible
│   │                                build (8 gated stages), dev/prod/lab profiles,
│   │                                regression + quiescence gates, apk keyring
├── baselines/0001/                ALLOY-BASELINE-0001 artifact + measurement scripts/logs
└── images/
    ├── pmos-qemu-aarch64.qcow2    ★ the working VM disk (2.1 GB)
    ├── krane-kukui.img            official Krane image, decompressed (2.6 GB)
    ├── krane-kukui.img.xz         same, compressed (591 MB) — the download artifact
    ├── vmlinuz + initramfs        kernel/initramfs copied from the VM build
    │                              (for direct `-kernel` boot fallback)
    ├── alpine-virt-3.22-aarch64.iso   rescue/bootstrap ISO (verified booting)
    └── firmware/vars-pmos.fd      EDK2 NVRAM vars (auto-recreated if deleted)
```

Disk footprint: ≈ 5.5 GB total.

## 5. Quick start

```sh
cd ~/Documents/gihhub/Kukui-krane

# GUI: opens a macOS window with the Phosh mobile desktop
./scripts/run-pmos-vm.sh

# Or headless (no window; serial logged to /tmp/pmos-serial.log)
./scripts/run-pmos-vm.sh headless

# Or serial console in the terminal itself
./scripts/run-pmos-vm.sh serial
```

Second terminal:

```sh
ssh -p 2222 user@localhost       # password: 147147
```

**Credentials**

| Where | User | Password |
|---|---|---|
| Console / SSH / sudo | `user` | `147147` |

Boot takes ~60–90 s from QEMU launch to SSH answering. The GUI window shows the
Phosh lock screen — unlock with `147147`.

Host → VM port forwarding: `host 2222 → guest 22 (ssh)`. Everything else is
outbound usermode NAT.

## 6. VM specification

| Component | Value |
|---|---|
| Machine | `qemu-system-aarch64 -M virt,highmem=on` (GICv3 + virtio platform) |
| Acceleration | `-accel hvf` (Apple Hypervisor.framework, near-native) |
| CPU | `-cpu host` (Apple M-series core; exposes your real cores' features) |
| vCPUs / RAM | 4 / 4096 MiB |
| Firmware | EDK2-stable202408 AArch64 (bundled with Homebrew QEMU 11.1.1) as pflash code + 64 MiB NVRAM vars file |
| Boot chain | UEFI → `EFI/BOOT/BOOTAA64.EFI` (systemd-boot) → `loader/entries/pmos.conf` → `vmlinuz` + `initramfs` |
| Kernel cmdline | `console=tty1 console=ttyAMA0,115200 psi=1` |
| Display | `virtio-gpu-pci` (software rendering via llvmpipe) |
| Input | `usb-tablet` (pointer), `usb-kbd`; emulated touchscreen surface |
| Disk | `virtio-blk` on `pmos-qemu-aarch64.qcow2` (4200 MiB, GPT) |
| Network | `virtio-net-pci` on usermode NAT, `hostfwd=tcp::2222-:22` |
| OS | postmarketOS **edge** (systemd variant), aarch64 |
| UI | **Phosh** (GNOME mobile shell) + greetd login manager |
| Kernel | pmOS `linux-stable` **7.2.4** (`device-qemu-aarch64-kernel-stable`) |
| Installed stack | postmarketos-base, firefox-esr, GNOME mobile apps (calls, chatty, console, contacts, maps…), flatpak, Plymouuth, ttyescape, mobile-config-firefox, … |

Machine types the real device would need but QEMU lacks: anything MediaTek —
there is **no `-M mediatek-mt8183` / `-M kukui` / `-M krane`**.

## 7. Hardware mapping: Krane → QEMU

| Layer | Real Krane | This VM | Fidelity |
|---|---|---|---|
| CPU arch | aarch64 (4×A73+4×A53 big.LITTLE) | aarch64 (`-cpu host`, uniform cores) | arch identical; no big.LITTLE topology |
| Kernel | `linux-postmarketos-mediatek-mt8183` 6.12.87 + Krane DTB | `linux-stable` 7.2.4 + virt DTB | same distro kernel base generation; **different drivers/DTB** |
| GPU | Mali-G72 MP3, Panfrost, GL ES 3.1 | virtio-gpu + llvmpipe (software GL) | rendering works; not Panfrost |
| Display | 10.1" 1920×1200 DSI panel | cocoa window / virtio-gpu framebuffer | Phosh sees a mobile-ish display |
| Touch / stylus | HID-over-I2C + USI | usb-tablet/usb-kbd | input works; no stylus pressure |
| WiFi / BT | QCA6174A ath10k (`LE_Krane` cal) | virtio-net usermode NAT | connectivity works; no WiFi/BT drivers |
| Audio | MT6358 codec | none configured | see known issues |
| Storage | eMMC | virtio-blk | block layer comparable |
| Bootloader | Coreboot → Depthcharge, `vmlinuz.kpart` | EDK2 UEFI → systemd-boot | different loader, same kernel+initramfs concepts |
| Service manager | systemd | systemd | identical |
| Userland | Alpine/postmarketOS aarch64 | Alpine/postmarketOS aarch64 | identical |

`docs/KRANE_SPECS.md` and `docs/QEMU_VS_KRANE.md` carry the same mapping with
source references.

## 8. What the VM CAN do

- **Boot a real postmarketOS mobile OS** end-to-end: EDK2 → systemd-boot →
  pmOS initramfs (stage 1 + stage 2) → switch_root → systemd → greetd → Phosh.
- **Phosh desktop experiments**: shell layout, on-screen keyboard, mobile
  settings, lock screen, top-bar/quick settings — the actual UI Krane runs.
- **Package experiments**: `apk add/search/delete`, pmOS + Alpine aarch64
  repos, building with `abuild`-style workflows, installing flatpaks.
- **SSH-driven automation**: password login on `localhost:2222`; the VM is a
  normal aarch64 Linux box for scripts, git, editors, CI-style testing.
- **systemd work**: units, targets, masks, service debugging — the same init
  system and largely the same units as on the phone/tablet.
- **Network experiments**: DHCP (inside NAT), DNS via systemd-resolved,
  outbound connections, listening services reachable via port-forwards you add
  to `-netdev user` (`hostfwd=...`).
- **postmarketOS specifics**: `/etc/os-release`, device package layout
  (`device-qemu-aarch64`), mkinitfs concepts, `os-release` edge channel,
  `pmos` boot scripts (`/pmOS_init.log`, `pmos_continue_boot`) — the same
  initramfs code that runs on real devices.
- **aarch64 development**: cross-arch correctness testing (endianness-free but
  pointer-size, alignment, ARM-specific builds) at native ARM speed — no qemu-user
  emulation slowness, because this is a full ARM VM on ARM hardware.
- **Snapshot / clone**: `qemu-img snapshot -c <name>` or copy the `.qcow2` for
  throwaway experiments (VM powered off).
- **Direct-kernel boot experiments**: `images/vmlinuz` + `images/initramfs`
  can be booted with `-kernel/-initrd -append "root=/dev/vda2 rw ..."` to skip UEFI.

## 9. What the VM CANNOT do

Be honest with yourself about these — no amount of configuration fixes them:

1. **Boot the actual Krane image / kernel / DTB.** No MT8183 machine model
   exists in QEMU; Depthcharge doesn't run there; the Krane DTB describes
   hardware `virt` doesn't have.
2. **Panfrost / Mali-G72 work.** No Mali GPU is emulated. GL comes from
   llvmpipe (software). Anything GPU-driver-specific is out.
3. **ath10k WiFi / QCA6174A / BT.** No PCI WiFi in usermode networking; no
   firmware loading, no calibration (`LE_Krane`) files apply.
4. **MT6358 audio codec paths.** The VM currently has no audio backend wired
   at all (see known issues).
5. **ChromeOS boot internals**: coreboot, Depthcharge, verified boot, kpart
   signing, CGPT boot flags — `virt` + EDK2 replaces this chain entirely.
6. **Touchscreen/stylus driver work** (HID-over-I2C, GTCH/I2C probe, USI).
   Input is emulated USB.
7. **eMMC-specific behavior** (mmc queues, partition scaling, wear) — virtio-blk
   is not eMMC.
8. **USB-C/DP-alt-mode, HPD, IT6505 bridge** — the Krane display-out path.
9. **Battery/PMIC/thermal/regulator code** (MT6358, CHARGER, thermal zones).

Rule of thumb: **userspace and workflow experiments transfer; kernel-driver and
bootchain experiments need the physical device.**

## 10. Known issues

| # | Issue | Impact | Status / workaround |
|---|---|---|---|
| 1 | `usb-signaller.service` fails | systemd reports state `degraded` instead of `running` | **Masked inside the image already** (`systemctl mask usb-signaller`). Harmless: the service exports initramfs logs over a USB gadget, which needs a real UDC — QEMU `virt` has none. |
| 2 | No GPU acceleration | Phosh/GTK apps render via llvmpipe → noticeably slower animation | Accepted limitation. `virtio-gpu` virgl (`-display cocoa,gl=on` + guest virgl mesa) is theoretically possible but **untested on macOS**; do not expect it to work out of the box. |
| 3 | Root fs ~3.5 GiB, partition capped at 3686 MiB | Big flatpaks (Firefox via flatpak) can fill the disk | Expand: grow qcow2 (`qemu-img resize +4G`), then inside a Linux host grow partition 2 and `resize2fs`. Note `pmos.force-partition-resize` was **removed** from the cmdline (see #4), so resizing is manual. |
| 4 | `pmos.force-partition-resize` removed from boot cmdline | Boot won't auto-grow the root fs | Deliberate: with a non-fsck'd fs the forced resize fails (`Please run 'e2fsck -f' first`) and the initramfs drops to its **debug shell**. Re-add the flag only if you also run `e2fsck -f` first. |
| 5 | EDK2 NVRAM (`images/firmware/vars-pmos.fd`) can corrupt on unclean VM shutdown | Boot falls to UEFI shell / no boot entry | Delete the file; the script recreates an empty 64 MiB vars store on next start. EDK2 auto-creates the "UEFI Misc Device" boot entry, so no manual `bootmgr` setup needed. |
| 6 | No serial output in `gui` mode | Can't debug boot from the window | Use `headless` mode (serial captured to `/tmp/pmos-serial.log` and interactive socket on `127.0.0.1:4445`) or `serial` mode. `quiet splash` was already removed from the cmdline for this reason. |
| 7 | Host port 2222 must be free | QEMU fails to start with `Could not set up host forwarding` | Change `hostfwd=tcp::2222-:22` in `run-pmos-vm.sh` to another port. |
| 8 | HVF restricts CPU models | Only `host`, `max`, `cortex-a53`, `cortex-a57` valid under `-accel hvf` | Use `host` (default). True A73/A73+big.LITTLE emulation requires `-accel tcg -cpu cortex-a72` (or A57) — 10–20× slower. |
| 9 | No audio device in the QEMU command line | VM is silent | Add `-audiodev coreaudio,id=snd -device ich9-intel-hda -device hda-output` (untested in this image). |
| 10 | No USB passthrough on macOS/HVF | Can't attach physical devices to the VM | Accepted (usbredir is unavailable on this host stack). |
| 11 | Timezone/locale defaults | VM runs `Etc/UTC`, `en_US.UTF-8` | Change inside the VM (`timedatectl set-timezone`, `setup-alpine`-style or `/etc/locale.conf`) if you care. |
| 12 | edge is a moving target | `apk upgrade` may pull breaking changes into the VM | That's inherent to pmOS edge. Snapshot the qcow2 before big upgrades. |
| 13 | `pmbootstrap install` cannot finish inside Docker | Partitioning step (`/dev/loop0p2`) never appears | Container kernel limits (`loop max_part=0`, no udev events). Worked around: rootfs is complete after the failed step; disk is assembled manually (`pmbootstrap-docker.sh fixup`). See §12. |
| 14 | pmbootstrap work dir must not be on a macOS bind mount | `chpasswd`/`passwd -l root` fail with "failure while writing changes to /etc/shadow" (virtiofs file-lock semantics) | Work dir lives at container-native `/home/pmos/pmwork` (overlayfs). Only the finished images cross to `/work` (the macOS mount). |
| 15 | Fresh rootfs has a **placeholder `/etc/fstab`** | initramfs can't mount `/boot`, boot dies into the debug shell | Injected real fstab (`/dev/vda1`, `/dev/vda2`) via `debugfs` during assembly. This was the final root-cause of the "debug shell every boot" bug. |
| 16 | USB gadget log export always errors in dmesg (`Couldn't write new UDC`, etc.) | Noisy but harmless initramfs messages | Expected: QEMU `virt` has no USB device controller. |
| 17 | Plymouth is still installed | GUI boots are silent on serial (plymouth owns tty1) | Cosmetic. `console=ttyAMA0` still gets a getty. |

## 11. Troubleshooting cookbook

### VM boots into "postmarketOS debug shell"

The pmOS initramfs hit a failure before `switch_root`. Diagnosis:

```
cat /pmOS_init.log        # full init log
pmos_continue_boot        # skip the shell, retry/continue boot
```

Known causes in this lab's history (in the order we hit them):
1. Partition labels missing → root not found. Fix: GPT names `pmOS_boot` /
   `pmOS_root` (§14).
2. `pmos.force-partition-resize` failing on an un-fsck'd fs → removed the flag
   (known issue #4).
3. Empty `/etc/fstab` in a fresh pmbootstrap rootfs → `wait_boot_partition`
   fails → `fail_halt_boot`. Fix: inject fstab (§13 step 8).

### SSH says "connection refused"

VM not up yet (wait 60–90 s) or QEMU not running. Check:

```sh
pgrep -fl qemu-system-aarch64
nc -z localhost 2222
tail -40 /tmp/pmos-serial.log      # headless mode
```

### SSH password rejected

User `user`, password `147147` — exactly. If you re-imaged, that's the
`--password` passed to `pmbootstrap install`.

### GUI window is black

Phosh may take a while on first boot (user session creation). If it stays
black: kill the VM, start `headless`, confirm the boot reaches
`qemu-aarch64 login:` on serial, then retry GUI. Also check known issue #5
(delete `vars-pmos.fd`, restart).

### VM clock is wrong / TLS errors inside the VM

The VM has no RTC sync guarantee; run `sudo apk add chrony` or set the date
manually, and prefer `apk` mirrors over HTTPS-heavy ops until time is right.

### Reset the VM to factory

Re-run the build pipeline (§13) or restore a qcow2 snapshot/copy you made
earlier. Deleting `vars-pmos.fd` resets UEFI state only.

### Enlarge the disk

```sh
# host, VM off
qemu-img resize images/pmos-qemu-aarch64.qcow2 +4G
# then boot the Alpine rescue ISO or a Linux live env, and:
#   parted: grow partition 2 to 100%
#   e2fsck -f /dev/vda2 && resize2fs /dev/vda2
```

(Don't re-add `pmos.force-partition-resize` instead — see issue #4.)

### Serial console cheat sheet

- `headless` mode: log at `/tmp/pmos-serial.log`; interactive:
  `nc 127.0.0.1 4445`.
- `serial` mode: interactive in the terminal (Ctrl-A X to quit QEMU).
- Console devices: `tty1` (GUI) and `ttyAMA0,115200` (serial getty).

## 12. Build pipeline: how the image was made

The full story, including every blocker hit and its resolution. This section is
the record of **why** the scripts look the way they do.

### 12.0 Why Docker

`pmbootstrap` officially supports Linux only (it drives privileged chroots,
loop devices, binfmt). On macOS it must run in a Linux container. Docker
(OrbStack/colima/Desktop) works, with the caveats below.

### 12.1 Toolchain install (host)

```
brew install qemu          # 11.1.1 — includes edk2-aarch64-code.fd + hvf
```

Verified: `qemu-system-aarch64 -accel help` → `hvf`, `tcg`.

### 12.2 Container setup

- Image: `ubuntu:24.04`, run `--privileged` (needs broad device access for
  chroot mount namespaces).
- Packages: `git python3 openssl sudo parted e2fsprogs dosfstools
  qemu-user-static kpartx multipath-tools e2tools mtools fdisk`
  (`qemu-user-static` for transparent aarch64 chroot execution; `e2tools` for
  reading ext4 without loop mounts).
- pmbootstrap cloned from gitlab.postmarketos.org (`/opt/pmbootstrap`,
  version 3.11.1 at build time), symlinked into `/usr/local/bin`.
- Dedicated non-root user `pmos` (pmbootstrap refuses root), sudoers NOPASSWD.
- **Gotcha #1 (virtiofs):** the pmbootstrap work dir was first placed on a
  macOS bind mount (`/Users/...`). `pmbootstrap install` then died at
  `passwd -l root` → *"failure while writing changes to /etc/shadow"* —
  file-locking semantics on the shared filesystem. **Fix:** work dir at
  container-native `/home/pmos/pmwork`; only final artifacts are copied out
  to the mount (`/work`).

### 12.3 pmbootstrap configuration

Non-interactive config (defaults accepted for the rest):

```
pmbootstrap init --shallow-initial-clone     # edge channel, pmaports main
pmbootstrap config work   /home/pmos/pmwork
pmbootstrap config device qemu-aarch64      # community device
pmbootstrap config ui     phosh             # same UI as Krane's port
pmbootstrap config user   user
```

That selects `device-qemu-aarch64` + `device-qemu-aarch64-kernel-stable` +
`postmarketos-ui-phosh` (which pulls systemd by default on edge).

### 12.4 The build, and why it "fails"

`pmbootstrap install --password 147147` runs four phases:
prepare native chroot → **create device rootfs** → prepare install blockdevice
→ create image.

Phase 2 **succeeds completely**: it builds/downloads ~200 packages (firefox-esr,
phosh, gnome-mobile apps, flatpak, plymouth, kernel 7.2.4…) and populates
`$PMWORK/chroot_rootfs_qemu-aarch64` — a full, bootable root filesystem.

Phase 3–4 **fail in Docker**: `create qemu-aarch64.img (3086M)` then
`ERROR: File did not appear: /dev/loop0p2`. Root causes: the container kernel
exports `loop/max_part=0` (loop devices never expose partitions), and there is
no udev in the container to synthesize partition events. We tried running
`systemd-udevd` manually — the loop partition naming still can't appear.

**Gotcha #2 (losetup):** accepted — the disk image is assembled manually from
phase 2's output (below). This is why `pmbootstrap-docker.sh` has a `fixup`
command.

### 12.5 Manual disk assembly (the `fixup` path)

Everything below runs in the container against `/work/images/` (the macOS mount):

1. **Root fs**: `mkfs.ext4 -F -L pmOS_root -d <rootfs> rootfs2.ext4 3500M`
   (`-d` populates the fs directly from the chroot tree — no copying step).
   - **Gotcha #3 (stray root file):** a root-owned `.pwd.lock` in the chroot
     aborts mkfs populate as user `pmos` → run as root in the container.
2. **Clean fs**: `e2fsck -f -y` + `resize2fs` (grow to fill 3686 MiB partition)
   + `e2fsck -f -y` again. This pre-empts the initramfs resize path entirely.
3. **ESP**: `mkfs.vfat -C -F 32 -n PMOS_BOOT pmboot.fat 524288` then
   `mcopy -s -i pmboot.fat $R/boot/* ::` — lands `vmlinuz`, `initramfs`,
   `EFI/BOOT/BOOTAA64.EFI` (systemd-boot), `loader/entries/pmos.conf`,
   `config`, `System.map`, `dtbs/`.
4. **Boot entry** rewritten to:
   ```
   title postmarketOS
   linux vmlinuz
   initrd initramfs
   options console=tty1 console=ttyAMA0,115200 psi=1
   ```
   `quiet splash plymouth.*` dropped (serial visibility) and
   `pmos.force-partition-resize` dropped (known issue #4).
   - **Gotcha #4 (partition labels):** GPT partitions are named `pmOS_boot`
     (`esp` flag on) and `pmOS_root` — the pmOS initramfs looks for these.
5. **fstab injection** — the critical one:
   - **Gotcha #5 (placeholder fstab):** a pmbootstrap device rootfs carries a
     comment-only `/etc/fstab` ("This file is *not* used to mount / or /boot").
     On normal installs pmbootstrap writes the real fstab during imaging; our
     manual path must replicate that. With the placeholder left in place, the
     initramfs finds no boot device entry, `wait_boot_partition` times out,
     `fail_halt_boot` fires and every boot lands in the debug shell. (The
     initramfs itself is "merged-extra" mode: `init.sh` jumps straight to
     `init_2nd.sh`, so `initramfs-extra` is **not** needed — the initial
     "initramfs-extra not found" hypothesis was a red herring.)
   - Fix:
     ```
     printf '/dev/vda1  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,utf8  0  1\n/dev/vda2  /      ext4  rw,relatime  0  1\n'
     debugfs -w -R 'rm /etc/fstab'        rootfs2.ext4
     debugfs -w -R 'write /tmp/fstab.new /etc/fstab' rootfs2.ext4
     ```
6. **Image**: 4200 MiB GPT (`parted`), ESP at 1 MiB, root at 513 MiB,
   `dd` both filesystems in, copy the raw to `/work/images/`.
7. **Host**: `qemu-img convert -O qcow2` → `images/pmos-qemu-aarch64.qcow2`.

### 12.6 Boot verification loop

Driving the serial console non-interactively from the Mac had its own traps:

- A FIFO-fed `-serial stdio` QEMU **blocks on open()** until a writer connects
  → the launcher "hung" and the tool's timeout killed the whole process group.
- Final pattern: QEMU detached (`nohup … & disown`), serial as
  **TCP socket chardev** with a server-side logfile:

```
-chardev socket,id=ser0,host=127.0.0.1,port=4445,server=on,wait=off,logfile=/tmp/pmos-serial.log
-serial chardev:ser0
```

Probe/interact with `nc 127.0.0.1 4445`; read `/tmp/pmos-serial.log` for history.

Progression observed and fixed, in order: UEFI shell (stale NVRAM) → initramfs
debug shell (partition labels) → debug shell (force-resize) → **login prompt**
(fstab fix) → **SSH session verified** → `usb-signaller` masked.

## 13. Rebuilding from scratch, step by step

```sh
# 0. prereqs (once)
brew install qemu
cd ~/Documents/gihhub/Kukui-krane

# 1. container + pmbootstrap + config
./scripts/pmbootstrap-docker.sh setup

# 2. build the rootfs ( finishes even though the final imaging step errors )
docker exec -u pmos -it pmb-kukui-lab bash
pmbootstrap install --password 147147      # ignore the loop0p2 failure at the end
exit

# 3. assemble the bootable disk (all the §12.5 steps, scripted)
./scripts/pmbootstrap-docker.sh fixup

# 4. convert + boot
qemu-img convert -O qcow2 images/pmos-qemu-aarch64.raw images/pmos-qemu-aarch64.qcow2
./scripts/run-pmos-vm.sh headless
ssh -p 2222 user@localhost                  # 147147
```

If you ever want the **google-kukui (real Krane) rootfs** instead: reconfigure
with `pmbootstrap config device google-kukui`, rebuild, and use the same
fixup flow — but remember the result still only boots on real MT8183 hardware.

## 14. Disk layout reference

```
images/pmos-qemu-aarch64.qcow2 — 4200 MiB, GPT
┌────┬───────────┬──────────┬────────┬──────────────────────────────────┐
│ #  │ Name      │ Range    │ FS     │ Contents                         │
├────┼───────────┼──────────┼────────┼──────────────────────────────────┤
│ 1  │ pmOS_boot │ 1–513 MiB│ FAT32  │ EFI/BOOT/BOOTAA64.EFI,           │
│    │ (esp)     │          │        │ loader/entries/pmos.conf,        │
│    │           │          │        │ vmlinuz, initramfs, dtbs/        │
│ 2  │ pmOS_root │ 513–4199 │ ext4   │ postmarketOS edge rootfs         │
│    │           │ MiB      │        │ (label pmOS_root, ~3.5 GiB used) │
└────┴───────────┴──────────┴────────┴──────────────────────────────────┘
```

Compare the official Krane image (§17): same *concepts* (named pmOS_*
partitions) but a `chromeos_kernel`-flagged kpart instead of an ESP, because
Depthcharge loads the kernel directly.

## 15. The real-hardware track

`images/krane-kukui.img` is the official `google-kukui` release image:

- Source: `https://images.postmarketos.org/bpo/v25.12/google-kukui/phosh/20260803-0403/`
- File: `20260803-0403-postmarketOS-v25.12-phosh-25-google-kukui.img.xz` (591.5 MiB)
- SHA-256: `3165c349cfb1f7eea0aabf98203826d282dd727c43511dab50ced76452304bdf`
  (verified locally against the published `.sha256`)
- Decompressed: 2.65 GiB, GPT:
  - p1 `pmOS_kernel` 4–36 MiB, `chromeos_kernel` flag (Depthcharge kpart)
  - p2 `pmOS_boot` 36–548 MiB, ext2 (vmlinuz, **6.12.87**, initramfs, dtbs incl.
    `mt8183-kukui-krane-sku0.dtb` + `sku176.dtb`)
  - p3 `pmOS_root` 548–2710 MiB, ext4 (`os-release`: postmarketOS v25.12)

**Flashing a physical Duet** is its own procedure (ChromeOS developer mode,
breaking/re-establishing the boot flow on MT8183, pmbootstrap flasher vs. image
copy) and changes with pmOS releases — follow the official wiki page for
[`google-krane`](https://wiki.postmarketos.org/wiki/Lenovo_IdeaPad_Duet_Chromebook_(google-krane))
rather than any hardcoded steps here. The image in `images/` is kept for
analysis and as the flashing source; treat it as v25.12-vintage, not "latest".

What transfers from VM experiments to the device: everything in userspace —
UI config, packages, scripts, service units, network behavior. What does not:
anything touching MT8183 drivers, Depthcharge, Panfrost, ath10k, or the panel.

## 16. FAQ

**Q: Can I run the real Krane kernel/DTB in QEMU to test driver changes?**
No. Without an MT8183 machine model the DTB describes hardware that doesn't
exist; drivers would fail at probe. Use the physical device or a kernel CI.

**Q: Then what's the VM actually good for?**
Everything above the kernel-driver line: the exact distro, UI, session stack,
package management, and systemd environment Krane runs — at native ARM speed,
with snapshots and SSH.

**Q: Why is the VM "postmarketOS edge" while the Krane image is "v25.12"?**
Edge is what current pmbootstrap builds by default and what the Kukui port
tracks; the v25.12 release image is a frozen snapshot of the same port. The VM
can be pinned to a stable channel in `pmbootstrap config` if you want parity.

**Q: Why systemd and not OpenRC?**
Krane's pmOS port defaults to systemd on edge (postmarketos-ui-phosh choice);
the VM mirrors that. OpenRC variants exist but weren't built here.

**Q: How do I snapshot before an experiment?**
VM off: `qemu-img snapshot -c pre-exp images/pmos-qemu-aarch64.qcow2`, then
`-a pre-exp` to roll back. Or copy the qcow2 file.

**Q: Can I get a bigger screen resolution in the GUI?**
The virtio framebuffer follows the window; Phosh's mobile shell will letterbox
its 360–720 px-wide phone layout. Resize behavior is Phosh's, not QEMU's.

**Q: Where are the boot logs?**
`/tmp/pmos-serial.log` (headless), or the socket on `127.0.0.1:4445`. Inside
the VM: `journalctl -b`, and the initramfs log at `/pmOS_init.log` during
initramfs stops.

**Q: Can I add audio / more RAM / more CPUs?**
RAM and vCPUs: edit `run-pmos-vm.sh` flags. Audio: known issue #9. WiFi/BT:
not possible (§9).

## 17. Verification record

Everything below was actually executed and observed while building this lab
(not extrapolated):

- **Host**: macOS (Darwin 25.6.0, arm64, Apple M-series), Homebrew QEMU 11.1.1
  with `hvf` listed as available accelerator.
- **Alpine sanity boot**: `alpine-virt-3.22.1-aarch64.iso` booted under
  `-M virt -accel hvf -cpu host` to the `localhost login:` prompt
  (`Linux 6.12.38-0-virt (aarch64)`), confirming the machine + firmware path.
- **Official Krane image**: downloaded, SHA-256 matched the published
  `.sha256` byte-for-byte; `parted` printed the three-partition layout above;
  `e2ls/e2cp` extracted `/config` (kernel 6.12.87 arm64 config) and
  `/usr/lib/os-release` (postmarketOS v25.12); boot partition listing shows the
  full `mt8183-kukui-*` DTB family including both Krane SKUs.
- **Built VM rootfs**: postmarketOS edge, `PRETTY_NAME="postmarketOS edge"`,
  kernel package 7.2.4, Phosh + greetd + systemd stack, ~2.1 GB populated tree.
- **Boot evidence (final image)**: serial log shows UEFI →
  `BdsDxe: starting Boot0001 "UEFI Misc Device"` → pmOS initramfs STAGE 1/2 →
  `Switching root` → systemd targets → `Migrate /etc/resolv.conf to the
  systemd-resolved stub` → `qemu-aarch64 login:`.
- **SSH evidence**: interactive session over `localhost:2222`:
  `Linux qemu-aarch64 7.2.4 #1-stable SMP PREEMPT … aarch64`,
  `PRETTY_NAME="postmarketOS edge"`, `loginctl` shows greetd + user session
  managers running; `systemctl --failed` empty after masking
  `usb-signaller.service`.
- **Repeat boot**: `./scripts/run-pmos-vm.sh headless` from a fresh shell
  reaches SSH in ~90 s, reproducibly.

## 18. Sources

Primary references used for the research and the mapping:

- Linux mainline DT: `mt8183-kukui-krane-sku176.dts` (github.com/torvalds/linux)
- coreboot `src/mainboard/google/kukui/Kconfig.name` (BOARD_GOOGLE_KRANE)
- ChromeOS device DB: next.cros.tech — krane (EOL, final stable 145)
- ChromeOS.Guide — Kukui baseboard devices (LenovoKrane / LenovoKraneIP)
- postmarketOS wiki — *Google Kukui Chromebook (google-kukui)*,
  *Lenovo IdeaPad Duet Chromebook (google-krane)*
- postmarketOS package index — `device-google-kukui` 13-r0 (krane in family)
- postmarketOS official images — `bpo/v25.12/google-kukui/phosh/`
- postmarketOS release notes — v26.06 "Alpen Avocado" (Kukui in community)
- VelvetOS Krane feature matrix (Panfrost GL ES 3.1, Hammer touchpad, stylus)
- pmbootstrap docs — installation/usage/cross-compiling (Linux-only, QEMU
  machine notes from QEMU's target-arm docs)

Local analysis documents: `docs/KRANE_SPECS.md`, `docs/QEMU_VS_KRANE.md`.

---

*Lab built September 2026 on Apple Silicon. All gotchas in §10/§12 were hit,
diagnosed, and resolved during the build — nothing here is theoretical.*
