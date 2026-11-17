# ALLOY-BASELINE-0002

**Second measured reduction** of the stripped postmarketOS baseline — file-level
and config-level cuts on top of ALLOY-BASELINE-0001, plus the full
*what-else-can-be-stripped* analysis (executed / blocked / gated / structural).

| | |
|---|---|
| ID | ALLOY-BASELINE-0002 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0001 (`baselines/0001/alloy-baseline-0001.qcow2`, kept pristine) |
| Artifact | `baselines/0002/alloy-baseline-0002.qcow2` (754 MiB) |
| Packages | 267 — unchanged by design (all 0002 cuts are file/config level) |
| Health | 0 failed units; NM, sshd, resolved, timesyncd, udevd, both gettys active |

---

## 1. Provenance

```
baselines/0001/alloy-baseline-0001.qcow2 (881 MiB, pristine)
  └─ baselines/0002/overlay-0002.qcow2        cuts applied here
      └─ baselines/0002/alloy-baseline-0002.qcow2 (754 MiB, flattened)
```

## 2. Executed cuts (each verified before/after)

| # | Cut | Why it's safe | Size freed |
|---|---|---|---|
| 1 | `/boot/dtbs` (whole tree) | systemd-boot entry has **no `devicetree` line**; `-M virt` supplies its own DTB to the kernel. The tree contains 42 vendor families — pure kernel-package cargo. | **117.2 MB** |
| 2 | `/boot/System.map` | Debug symbols; unused at boot. (`/boot/config` kept — useful for kernel work.) | 11.6 MB |
| 3 | `/var/lib/swcatalog` | AppStream catalog (XML + icons) for GNOME Software, which no longer exists. | 11.3 MB |
| 4 | `/var/lib/greetd` + users `greetd`, `geoclue`, `avahi`, `pulse` + `/var/lib/{geoclue,plymouth,flatpak,udhcpd,xfsprogs}` | greetd's full GNone-flavored home (chatty DB, evolution caches, mesa shader cache…) left behind by the package removal. | 10.5 MB |
| 5 | journald `SystemMaxUse=10M` (+ vacuum) | Cap persistent journal; steady state 19 MB → 8.5 MB. | 11 MB |
| 6 | `systemctl mask` systemd-oomd + coredumpd (service + sockets + register) | Userspace OOM daemon and core-dump plumbing; kernel OOM killer remains. Reversible (`systemctl unmask`). | −2 services, −2.9 MB RSS |
| 7 | `/var/cache/{apk,distfiles,misc,swcatalog,fontconfig,private}` | Re-downloads on demand. | 7.0 MB |
| 8 | `/etc/tuned`, `/var/log/tuned` | Leftovers of the removed tuned stack. | ~1 MB |

Note on ESP: vfat needs its own `fstrim -v /boot` — the root-fs trim does not
cover it. Both filesystems trimmed before compaction (boot trim deallocated
~477 MB of the 512 MB ESP's free space).

## 3. Metrics

| Metric | Pre-strip | 0001 | **0002** | Δ 0001→0002 |
|---|---|---|---|---|
| Image size (qcow2) | 2208 MiB | 881 MiB | **754 MiB** | −14 % |
| Root fs used | 2.0 GB | 671 MB | **632 MB** | −6 % |
| `/var` | 67 MB | 48 MB | **9 MB** | −81 % |
| Boot RAM (used / available) | 183 / 3430 MiB | 107 / 3590 | **103 / 3594** | −4 MiB |
| Process count | 130 | 105 | **103** (≈5 are the SSH probe) | −2 |
| Running services | 27 | 16 | **14** | −2 |
| Boot → SSH (host) | 12.5 s | 12.9–15.9 s | **12.6 s** (see §6) | unchanged |
| systemd-analyze total | 10.08 s | 9.48–11.72 s | **9.34 s** (fw 5.48 + loader 0.14 + kernel 1.26 + userspace 2.46) | best yet |
| Idle wakeups (60 s) | 114.9 IRQ/s | 28.1 IRQ/s | **23.9 IRQ/s** | −15 % |
| Packages / payload | 1187 / 2081 MB | 267 / 632 MB | 267 / 632 MB | unchanged (by design) |

Wakeup breakdown (0002): arch_timer 20.2/s (HVF host tick floor),
function-call IPIs 3.5/s, virtio < 0.3/s. The remaining floor is the
hypervisor's timer behavior, not guest work — on real Krane hardware the
equivalent number will be governed by the kernel's tickless behavior instead.

## 4. Dig-deeper findings: what *cannot* be cut at the apk level (and why)

Verified with `apk del --simulate` (read-only) against the real index:

| Candidate | Verdict | Blocked by |
|---|---|---|
| `llvm22-libs` (168 MB — the biggest single item left) | **load-bearing** | `libdril_dri.so` links `libLLVM.so.22.1` (llvmpipe lives inside `libgallium-26.1.6.so`, 37 MB). Removing LLVM cascades out `mesa-dri-gallium`, `mesa-gbm`. Only a pmaports rebuild (panfrost-only, no llvmpipe) can drop it. |
| `spirv-tools` (5.5 MB) | hard dep | `mesa` itself depends on it |
| `nss` + `nspr` (4.7 MB) | hard dep | `networkmanager` |
| X11 client stack: `libx11`, `libxcb`, `libxau`, `libxdmcp`, `xkeyboard-config` (~14 MB incl. `/usr/share/X11`) | hard dep | `mesa` (libGL→X11), `pipewire`, `wireplumber`, `alsa-lib/-utils`, `alsa-plugins-pulse` |
| `cracklib-words` + `libpwquality` (~11 MB) | hard dep | `postmarketos-base`, `postmarketos-base-systemd` (PAM password quality) |
| `tpm2-tss-*` (5 pkgs) | hard dep | bluez/libinput/NM chain |
| `xfsprogs-extra` (2 MB) | hard dep | `postmarketos-base` / initramfs chain |
| `font-terminus`, `util-linux-misc` (8.6 MB) | hard dep | `postmarketos-base`, `device-qemu-aarch64` |
| `buffyboard`, `beebzzr`, `iskey`, `treescan`, `scanelf`, `tdb-libs`, `inotify-tools`, `dialog` | hard dep | postmarketos-base dependency web |

Conclusion: the apk-level surface on top of 0001 is exhausted except for the
profile decision below. Further package-level reduction requires pmaports
changes (device package / base package / mesa recipe), not host-side `apk del`.

## 5. Remaining queue

**Profile-gated (need an explicit Krane-parity vs QEMU-minimal decision):**
- `wpa_supplicant` + `bluez` + `rtkit`: sim shows a clean 9-package removal,
  **−10.3 MB disk, −5.5 MB RSS** (cascades `libmm-glib`, `libnl3`,
  `pcsc-lite-libs`). All three are Krane hardware-relevant (WiFi/BT/audio) but
  inert in QEMU. Recommend: keep in the Krane-parity baseline; drop in a
  separate `qemu-min` profile if wanted.
- `NetworkManager` → `systemd-networkd`: −14.6 MB RSS, −~15 MB disk; large
  behavioral change; Krane runs NM. Not recommended for this baseline.
- `/etc/udev/hwdb.bin` (13.5 MB compiled hwdb) + `/usr/lib/udev/hwdb.d`
  (10 MB): trimmable/regenerable; needs a device-matching verification pass.
  Queued for 0003.

**Structural (bigger projects, each its own measured step):**
- LLVM-free Mesa for the Krane track (−168 MB; pmaports rebuild, panfrost-only).
- Kernel module pruning: `/usr/lib/modules` is 72 MB; only 10 modules ever load
  under `virt` (virtio, evdev, xhci…). File-level prune → ~20–25 MB, but kernel
  upgrades restore it; best done as a kernel-package variant later.
- initramfs feature trim (15.3 MB): `/etc/mkinitfs` ships only default dirs (no
  conf); a features-reduced mkinitfs config could shave a few MB and a bit of
  boot RAM — must be boot-verified.
- Kernel config slimming (vmlinuz 19.7 MB) — belongs to the real-Krane track.

## 6. Methodology notes (carried into future runs)

1. **Trim every filesystem**: `fstrim -v /` does not cover the vfat ESP; run
   `fstrim -v /boot` too, or compaction keeps the freed blocks (cost 0002 one
   extra compact cycle: 872 → 754 MiB).
2. **Idle the host before timed boots**: two boots measured 20–21 s while APFS
   was still settling after a 754 MB `qemu-img convert`; the identical image
   measured **12.6 s** on an idle host. Future records: ≥30 s quiet before the
   timed run, and prefer median-of-3.
3. **Collect ≥2 min after boot** (carried from 0001): the collector hangs if it
   races first-boot journald flush.
4. `apk del --simulate` can propose an *upgrade* of an unrelated package as a
   side effect (hwdata-pci 0.410→0.411). Real `del` runs must be watched for
   unintended upgrades — never run bare `apk upgrade` in a baseline.

## 7. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0002/alloy-baseline-0002.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0002/vars.fd
# login user/147147; root has key auth from the lab host
baselines/0001/measure-boot.sh  baselines/0002/alloy-baseline-0002.qcow2 \
    baselines/0002/serial-alloy3.log baselines/0002/timings-alloy3.txt 2222 \
    baselines/0002/vars.fd
baselines/0001/collect-metrics.sh <prefix> 60     # ≥2 min after boot
```

Artifacts in `baselines/0002/`: `alloy-baseline-0002.qcow2`, `overlay-0002.qcow2`
(throwaway), `vars.fd`, `timings-alloy{,2,3}.txt`, `serial-*.log`,
`guest-dig.sh`/`guest-dig2.sh` + `out/dig-deep*.txt` (forensics), and
`out/baseline-0002.*` (official metrics).

---
*All numbers executed and measured 2026-09-08. Next candidates: hwdb trim
(0003), profile decision on wpa/bluez/rtkit, then the structural tracks.*
