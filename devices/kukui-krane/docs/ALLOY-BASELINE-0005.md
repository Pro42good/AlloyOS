# ALLOY-BASELINE-0005

**Fifth measured reduction**: IRQ floor pushed to 8.7/s and a measured
zram→disk swap layering. Same constraints as before: configuration only —
sysctls, a swapfile, fstab — no forks, all upstream, all reversible.

| | |
|---|---|
| ID | ALLOY-BASELINE-0005 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0004 (`baselines/0004/alloy-baseline-0004.qcow2`, kept pristine) |
| Artifact | `baselines/0005/alloy-baseline-0005.qcow2` (734 MiB — +15 MiB: 2 GB swapfile metadata is sparse but swap/djurn churn is real) |
| Packages | 267 — unchanged |
| Health | 0 failed units; 12 services; survived a deliberate OOM-panic test and rebooted clean |

---

## 1. IRQ diet: 11.4 → 8.73/s

**What worked:**

- `vm.compaction_proactiveness = 0` (added to `/etc/sysctl.d/10-alloy-idle.conf`).
  Discovery: kcompactd was still waking **2.0/s even with THP=madvise** (0004)
  — *proactive* compaction runs on its own timer, independent of THP. Turning
  proactiveness off removes those timer arming; kcompactd now wakes only on
  real allocation failure (~0 at idle).

**What did not work (tested, honestly negative):**

- `kernel.watchdog=0` — this kernel build **has no such sysctl**
  (`/proc/sys/kernel/watchdog` absent). The soft-lockup detector idea was dead
  on arrival; the earlier A/B (10.7 → 11.7/s) was measuring noise.
- `vm.stat_interval=100` (vs 10) — no measurable change; reverted to 10 for
  stat freshness.

**Result (median boot, 60 s window):**

| IRQ line | 0004 | **0005** |
|---|---|---|
| arch_timer | 9.58/s | **7.25/s** |
| function-call IPIs | 1.42/s | **0.97/s** |
| virtio (net+block) | 0.45/s | 0.44/s |
| resched | 0.05/s | 0.05/s |
| **total** | **11.40/s** | **8.73/s** |

Remaining floor: ~7.3/s arch_timer + ~1.4/s everything else. Going lower means
`nohz_full`/tick tuning or kernel-config work — structural track. (And under
HVF, part of this rate is the host's scheduling cadence, not guest demand.)

## 2. Swap layering: zram (zstd) primary + disk overflow

```
/dev/zram0  zstd  5.7 GiB  priority 300   ← pmOS unit (unchanged)
/swapfile   —     2 GiB    priority 10    ← new: fallocate'd ext4 file, fstab:
                                             "/swapfile none swap sw,pri=10 0 0"
```

Order is guaranteed by priority: zram absorbs first; the disk file is pure
overflow (>5.7 GiB swapped — unreachable in this 4 GiB VM, real insurance on
Krane's 4 GiB under app churn).

**Measured behavior (the full pressure story):**

| Demand (tmpfs on 3.9 GiB RAM) | What happened |
|---|---|
| ≤ 3.5 GiB | **No swap at all** — demand never crossed the watermark; `avail` dipped to 39 MiB but kswapd never fired. Correct kernel behavior: idle offload is ~0 by design. |
| 3.9 GiB (crossing supply) | kswapd evicted ~740 MB — **zram absorbed it**: 382 MB logical → **200 KB stored** (zeros are same-filled pages: metadata only, mm_stat ≈ flat). Latency unchanged (apk probe 0.26–0.29 s at every stage). |
| 3.9 GiB with zram accidentally off | the **disk file** absorbed 632 MB (`/proc/swaps` 647 MB used), latency still unchanged — the fallback path demonstrably works. |
| 3.6 GiB *incompressible* (urandom, ~93 % of RAM) | **OOM → kernel panic** (`panic_on_oom` semantics — the trace shows `panic ← out_of_memory ← kernel_clone`). Clean fast-fail, rebooted to healthy state in ~2 min. |

**Usability under all pressure states**: apk search/update, DNS, SSH all
normal (0.26–0.29 s probes); 0 OOM events except the deliberate
incompressible-overrun test; system recovered to 0 failed units after the
panic.

**Verdict for Krane**: the layering converts memory *spikes* into smooth
operation as long as the working set is compressible (real apps are, ratios
2–4×); it cannot save an incompressible working set near 100 % of RAM — the
system fast-fails instead of thrashing. `swapoff -a` is forbidden in scripts
(see gotchas).

## 3. Gotchas logged (each bit us once)

1. **`swapoff -a` kills zram on pmOS** — zram is armed by
   `postmarketos-zram-swap.service`, not fstab; after `swapoff -a` only fstab
   swap returns. The unit re-arms on restart — but as the **next free zram
   device** (`zram0` → `zram1` if the old one still holds a swap signature).
   Monitor via `/proc/swaps`, never via fixed device paths. Never run
   `swapoff -a` on this baseline; use targeted `swapoff <dev>`.
2. **`rm -rf <mountpoint>` after umount deletes the directory** — the next
   `mount -t tmpfs ... /mnt` fails, and with stderr masked the writes fail
   silently. (Root cause of one wasted demo run.)
3. **`ps | grep -c X` counts the grep** — use `/proc/*/comm`.
4. `stderr 2>/dev/null` on the ssh *client* also swallows remote errors —
   mask locally only.

## 4. Metrics

| Metric | 0003 | 0004 | **0005** | Δ 0004→0005 |
|---|---|---|---|---|
| Idle wakeups | 22.8/s | 11.4/s | **8.73/s** | −23 % |
| Boot RAM (used / available) | 105 / 3595 | 101 / 3600 | **98 / 3607 MiB** | −3 MiB |
| Process count | 105 | 99 | **100** | ±1 |
| Running services | 14 | 12 | **12** | unchanged |
| Image size | 714 MiB | 719 MiB | **734 MiB** | +15 (swapfile + churn) |
| Root fs used | 622 MB | 632 MB | 2.6 GB* | *includes the 2 GB swapfile |
| Boot → SSH (median-of-3) | 12.4 s | 12.4 s | **12.4 / 12.4 / 12.5 s** | unchanged |
| systemd-analyze | 9.28 s | 9.29 s | **9.29 s** | unchanged |
| Swap devices | 1 (zram) | 1 (zram) | **zram + 2 GB disk file** | layered |
| Packages / payload | 267 / 632 MB | — | 267 / 632 MB | unchanged |

## 5. Revert

```sh
swapoff /swapfile && rm /swapfile && sed -i /swapfile/d /etc/fstab
sed -i /compaction_proactiveness/d /etc/sysctl.d/10-alloy-idle.conf
```

## 6. Remaining queue

Structural only: LLVM-free Mesa (−168 MB), kernel-module prune (72→~22 MB),
initramfs features (15.3 MB), `nohz_full`/kernel-config tick work (IRQ < 8/s),
journald `Storage=volatile` decision, lab-only direct-kernel boot.

## 7. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0005/alloy-baseline-0005.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0005/vars.fd
# demo scripts: baselines/0005/guest-ab.sh, guest-offload-demo*.sh
# battery: baselines/0001/measure-boot.sh + collect-metrics.sh (as before)
```

Artifacts in `baselines/0005/`: `alloy-baseline-0005.qcow2`, `overlay-0005.qcow2`,
`vars.fd`, `timings-b{1,2,3}.txt`, `serial-*.log`,
`out/offload-demo*.txt`, `out/baseline-0005.*`.

---
*Measured 2026-09-08. Cumulative from the Phosh image: 2208 → 734 MiB (−67 %),
183 → 98 MiB boot RAM, 27 → 12 services, **114.9 → 8.73 IRQ/s (−92 %)**,
1187 → 267 packages — every step measured, every failure recorded.*
