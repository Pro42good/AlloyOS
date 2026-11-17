# ALLOY-BASELINE-0003

**Third measured reduction**: udev hardware-database diet on top of
ALLOY-BASELINE-0002 — the largest remaining *config-safe* (non-pmaports) cut.

| | |
|---|---|
| ID | ALLOY-BASELINE-0003 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0002 (`baselines/0002/alloy-baseline-0002.qcow2`, kept pristine) |
| Artifact | `baselines/0003/alloy-baseline-0003.qcow2` (714 MiB) |
| Packages | 267 — unchanged (file-level cut + recompile) |
| Health | 0 failed units; udev, NM, sshd, resolved, timesyncd, both gettys active; input classification verified across cold boot |

---

## 1. What was cut

The systemd hwdb is a compiled trie (`/etc/udev/hwdb.bin`) built from source
databases in `/usr/lib/udev/hwdb.d/`. Most of its mass is *name-lookup* data —
USB/PCI/MAC/ACPI IDs mapped to marketing strings — which nothing on a headless
system consumes. The *functional* quirk databases are tiny.

**Dropped (11 files, 9.1 MB of sources):**

| File | Size | Why safe |
|---|---|---|
| `20-pci-vendor-model.hwdb` | 4.3 MB | cosmetic `ID_*_FROM_DATABASE` names |
| `20-OUI.hwdb` | 3.1 MB | MAC → vendor names |
| `20-usb-vendor-model.hwdb` | 1.5 MB | USB names |
| `20-acpi-vendor.hwdb` | 158 KB | ACPI names |
| `20-bluetooth-vendor-product.hwdb` | 140 KB | BT names |
| `20-dmi-id.hwdb`, `20-sdio-vendor-model.hwdb` | <40 KB | names |
| `80-ieee1394-unit-function.hwdb` | 51 KB | FireWire naming — no FireWire |
| `40-imds.hwdb` | 7 KB | AWS instance metadata |
| `60-autosuspend-fingerprint-reader.hwdb` | 9 KB | no fingerprint reader |
| `60-tpm2.hwdb` | 7 KB | no TPM |

**Kept (functional/class/infra, ~380 KB total):** all `60-*` quirks
(`evdev`, `input-id`, `keyboard`, `seat`, `sensor`, `autosuspend`,
`autosuspend-chromiumos` — Krane is a ChromeOS device), all `70-*`
(mouse/touchpad/pointingstick/joystick/sound-card/…), the class + interface
naming databases (`20-pci-classes`, `20-usb-classes`, `20-sdio-classes`,
`20-vmbus-class`, `20-net-ifname`, `82-net-auto-link-local`).

**Regenerated:** `systemd-hwdb update` → `hwdb.bin` 13,516 KB → **288 KB**.

Net: **−22.4 MB** on disk, and because the regenerated trie recompiles from
whatever sources remain, future `systemd-hwdb update` runs stay small — this is
a stable state, not a fragile file deletion.

## 2. Verification (before compacting)

- `udevadm trigger` + udevd restart + reload: no errors
- Input classification (from udev's `input_id` builtin, hwdb-independent):
  - `event0` → `ID_INPUT=1 ID_INPUT_KEY=1` (PS/2-ish keyboard)
  - `event1` → `ID_INPUT_KEYBOARD=1` (usb-kbd)
  - `event2` → `ID_INPUT_MOUSE=1` (usb-tablet) — stable across a cold boot
- `eth0` naming intact (`20-net-ifname` kept), DHCP renews, `systemctl --failed` = 0
- Observed race during verification: `udevadm info` queried ~3 s after
  `udevadm trigger` returned empty properties; the same query after settling
  was correct. udev `trigger` returns before the event queue drains — always
  verify after a settle, never immediately.

## 3. Metrics

| Metric | 0001 | 0002 | **0003** | Δ 0002→0003 |
|---|---|---|---|---|
| Image size (qcow2) | 881 MiB | 754 MiB | **714 MiB** | −5.3 % |
| Root fs used | 671 MB | 632 MB | **622 MB** | −1.6 % |
| `/etc` | 17 MB | 16 MB | **3 MB** | −81 % |
| `/usr/lib` | 375 MB | 375 MB | **366 MB** | −9 MB |
| Boot RAM (used / available) | 107 / 3590 MiB | 103 / 3594 | **105 / 3595** | ±2 MiB (noise) |
| Process count | 105 | 103 | **105** | ±2 (SSH-probe noise) |
| Running services | 16 | 14 | **14** | unchanged |
| Boot → SSH (host, median-of-3) | 12.9–15.9 s | 12.6 s | **12.4 / 12.4 / 12.4 s** | consistent |
| systemd-analyze total | 9.48–11.72 s | 9.34 s | **9.28 s** (fw 5.48 + loader 0.12 + kernel 1.28 + userspace 2.40) | best yet |
| Idle wakeups (60 s) | 28.1 IRQ/s | 23.9 IRQ/s | **22.8 IRQ/s** | −1.1 (arch_timer 19.1/s floor) |
| Packages / payload | 267 / 632 MB | 267 / 632 MB | 267 / 632 MB | unchanged (by design) |

Read: 0003 is a pure *disk* win; runtime numbers are unchanged within the
noise band (±2 MiB RAM, ±2 procs, ~±1 IRQ/s), which is exactly what a
dormant-database cut should look like.

## 4. Where the remaining disk lives (post-0003, measured)

| Area | Size | Status |
|---|---|---|
| `/usr/lib/modules` (kernel 7.2.4) | 72 MB | structural — kernel-package prune or Krane kernel variant |
| `/usr/lib` (rest) | 294 MB | llvm 168 MB + mesa/gallium 37 MB are load-bearing (see 0002 §4) |
| `/boot` (ESP) | ~37 MB | vmlinuz 19.7 + initramfs 15.3 + config 0.3 + systemd-boot ~1 |
| `/usr/share` | 31 MB | alsa ucm2 (Krane MT6358), terminfo, keymaps, zoneinfo |
| initramfs | 15.3 MB | structural — mkinitfs features trim |
| apk payload | 632 MB | 267 pkgs; package-level surface exhausted (0002 §4) |

## 5. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0003/alloy-baseline-0003.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0003/vars.fd
# timed boots: baselines/0001/measure-boot.sh <img> <serial> <timings> 2222 \
#              baselines/0003/vars.fd   (idle host, median-of-3)
# metrics:     baselines/0001/collect-metrics.sh <prefix> 60   (≥2 min post-boot)
```

Artifacts in `baselines/0003/`: `alloy-baseline-0003.qcow2`, `overlay-0003.qcow2`
(throwaway), `vars.fd`, `timings-b{1,2,3}.txt`, `serial-*.log`,
`out/baseline-0003.*`.

---
*Measured 2026-09-08. Cumulative: 2208 MiB → 714 MiB image (−68 %), 183 → 105
MiB boot RAM, 27 → 14 services, 114.9 → 22.8 IRQ/s idle, 1187 → 267 packages.*
