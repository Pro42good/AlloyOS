# ALLOY-BASELINE-1001 — performance record

Formal measurement of the compiled new-base floor. Every number below was
executed on the frozen artifact (`alloy-1001-floor.qcow2`, sha256
`0586afc5…a7cc`), booted through a throwaway overlay.

## Environment (fixed geometry)

| | |
|---|---|
| Host | Apple M2, 16 GB, macOS 26.6.1, load avg 2.65 at measurement |
| Emulator | QEMU 11.1.1, `-accel hvf -cpu host`, `-M virt,highmem=on`, 4 vCPU, 4096 MiB |
| Devices | virtio-blk (discard=unmap), virtio-net (NAT, hostfwd 127.0.0.1:2222), xhci + usb-kbd/tablet, no display |
| Guest | Nura edge, kernel **7.3.4** (`#1-stable SMP PREEMPT`, built 2026-11-11), systemd **262** |
| Method | idle host, median-of-3 timed boots, metrics ≥2 min post-boot, 60 s IRQ window |

## Boot

| Measure | Value |
|---|---|
| Host: spawn → SSH auth | **12.6 / 12.4 / 12.5 s** (median **12.5 s**) |
| Guest `systemd-analyze` total | **9.504 s** |
| — firmware (EDK2) | 5.483 s |
| — loader (systemd-boot) | 0.192 s |
| — kernel | 1.255 s |
| — userspace | **2.573 s** |

Firmware dominates; userspace is 27 % of total. Comments: UEFI verbose
(5.5 s) is the same cost as on the 7.2.4 lineage — a lab-only direct-kernel
boot would remove it (not comparable, documented).

## Memory

| Measure | Value |
|---|---|
| Used (settled) | **106 MiB** (of 3895 total, 3596 available) |
| Swap used | **0 B** of 7890 MiB (zram 5.7 G pri 300 + 2 G swapfile pri 10) |
| Process count | **102** |

Top RSS: NetworkManager 15.6 MB, systemd-journald 12.9 MB, systemd (pid1)
12.2 MB, systemd (user) 9.1 MB, systemd-udevd 8.5 MB, sshd-session 6.6 MB,
systemd-resolved 5.7 MB. Nothing above 16 MB; no leaks; zram untouched.

## Services (13 running)

`apk-inhibit · dbus-broker · getty@tty1 · NetworkManager · routewrangler ·
serial-getty@ttyAM0 · sshd · systemd-journald · systemd-logind ·
systemd-resolved · systemd-timesyncd · systemd-udevd · user@0`
(avahi installed-but-masked; wpa_supplicant/rtkit disabled; oomd/coredumpd masked)

## Interrupts / idle wakeups

60 s windows, sampled at four points during the session:

| Window | Total IRQ/s | arch_timer | function-call IPI | virtio (blk+net) | resched |
|---|---|---|---|---|---|
| A (post-avahi) | **9.70** | 7.5 | 1.3 | ~0.7 | 0.05 |
| B (post-avahi, settled) | **8.67** | 7.3 | 1.1 | ~0.5 | 0.05 |
| C (perf collection) | **9.32** | 7.33 | 1.28 | 0.42+0.12+0.07 | 0.05 |
| D (per-PID profile) | **10.45** | — | — | — | — |

Floor band: **8.7–10.5 IRQ/s** (window variance ±1). Composition:
`GICv3 arch_timer` (HVF host-scheduling floor) **7.3–7.5/s**, function-call
IPIs ~1.1–1.3/s (TLB/vmstat fold), virtio requests 0.4–0.7/s, rescheduling
0.05/s, MSI-X output/input ~0.05/s.

Per-process wakeups (60 s): kworker/u16 28 + 26, rcu_preempt 25,
**routewrangler 12**, jbd2 6 — no userspace service exceeds ~0.2 wakes/s.

## Storage

| Measure | Value |
|---|---|
| Artifact | **435 MiB** compressed qcow2 (virtual 4.1 GiB) |
| Root fs used | 2.7 GB incl. 2 GB swapfile (live data ~700 MB) |
| `/usr` | 457 MB |
| Kernel modules | **638 files / 21.4 MB** on disk; **17 loaded** (incl. the
  nftables stack `nf_tables`/`nft_ct`/`nf_conntrack` loaded by pmOS plumbing,
  `i2c_dev`, `virtiofs`, `fuse`, `evdev`, `hid_generic`, `uhid`,
  `libcomposite` from the initramfs copy) |

## Host-side cost (idle)

| | |
|---|---|
| QEMU process CPU | **0.0 %** (`ps` %cpu, 3:47 elapsed) |
| QEMU RSS | 139 MiB |
| Sandbox overlay growth over session | 12.3 MiB (journal/config churn) |

## Versus the previous lineage (0007, kernel 7.2.4)

| Metric | 0007 | **1001** | Note |
|---|---|---|---|
| Boot (median) | 12.4 s | 12.5 s | firmware-bound |
| Userspace boot | 2.4 s | 2.573 s | +0.17 s (systemd 262, console kit) |
| Boot RAM | 96–105 MiB | **106 MiB** | +1–10 |
| Processes | ~100 | 102 | — |
| Services | 12 | 13 | routewrangler kept, avahi masked |
| Idle IRQ/s | 6.9–7.1 | **8.7–10.5** | +1.6–3.4; arch_timer slightly higher on 7.3.4/HVF |
| Modules (files/MB) | 625 / 21.9 | 638 / 21.4 | trivial |
| Artifact (compressed) | 349 MiB | 435 MiB | console-UI base is slightly larger |

**Reading:** the floor's behaviour carries over; the new base costs ~1 IRQ/s
and ~5–10 MiB more while adding a newer kernel (7.3.4) and systemd 262.
Remaining headroom is structural (LLVM-free Mesa, initramfs trim, tickless).

## Raw evidence

`baselines/1000/out/perf-1001.{system,ram,processes,systemd-analyze,wakeups,disk}.txt`

---
*Measured 2026-11-17 on the frozen artifact; overlay-only boot; host load
2.65. Compare with `docs/ALLOY-BASELINE-1000-1001.md` for the recipe deltas.*
