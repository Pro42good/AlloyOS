# ALLOY runtime profile — what is actually running, and what can be tuned

**Scope**: ALLOY-BASELINE-0003 artifact, 60 s true-idle window, measured
in-guest with a minimal sampler (`/proc/[0-9]*/{stat,status,io}` deltas,
host-side join). **All proposed changes are customization: sysctls, kernel
cmdline params, systemd drop-ins and enablement choices, journald config —
no package changes, no patches, no forks. Everything stays upstream pmOS.**

| | |
|---|---|
| Artifact | `baselines/0003/alloy-baseline-0003.qcow2` |
| Window | 60 s, ≥20 s settle after boot, no SSH traffic during window |
| Method | per-PID `utime+stime`, `voluntary_ctxt_switches`, `write_bytes` deltas |

---

## 1. The measured idle profile

### Headline

- **Userland CPU: 0.000 s across all 95 processes in 60 s.** Nothing is computing.
- **Disk writes at idle: 0 KB from every process.** Nothing is writing.
- **Total IRQ rate: 25.0/s.** Breakdown: `arch_timer` 19.1/s (HVF hypervisor
  tick — lab floor, not guest cost), function-call IPIs 3.4/s, resched 0.05/s,
  virtio < 0.3/s combined.
- Every systemd service except the ones below wakes **≤1 time per 60 s**.

### Who still wakes (voluntary context switches, 60 s)

| Process | Wakes | Rate | Cause |
|---|---|---|---|
| kcompactd0 | 117 | 2.0/s | THP `[always]` + khugepaged 10 s scan → compaction churn |
| kworkers (8 threads) | ~260 | 4.3/s | workqueue housekeeping — mostly `vm.stat_interval=1` (per-CPU 1 s vmstat) + block flush |
| psimon ×5 | 22 | 0.4/s | PSI monitors — `psi=1` on cmdline (pmOS), systemd registers pressure watches even with oomd masked |
| wpa_supplicant | 6 | 0.1/s | no WiFi device present (kept for Krane parity) |
| jbd2/vda2, systemd, resolved, timesyncd | 1–3 | ~0.03/s | ext4 journal tick, PID 1 self-maintenance — floor |

### Memory per service (cgtop + RSS, MiB)

| Service | RSS | Note |
|---|---|---|
| systemd-journald | 14.5 | largest; includes journald machinery |
| NetworkManager | 13–14.6 | networking essential (Krane parity) |
| systemd-udevd | 9.4 | |
| systemd-resolved | 6.7 | DNS |
| systemd-logind | 5.9 | |
| systemd-timesyncd | 5.4 | time sync |
| sshd (+ per-session 7) | 5 | per-session cost is the SSH probe itself |
| wpa_supplicant | 3.3–4.3 | **idle with no device** |
| dbus-broker (+launcher) | 3.6 | |
| user@0 | 3.4 | **root user manager — exists only because of the SSH probe** |
| rtkit-daemon | 1.4 | **no audio session running** |
| apk-inhibit | 1.0 | holds sleep inhibitor; zero dependents found |
| getty@tty1 + serial-getty | 1.1 | console logins |

### Effective config found

`vm.stat_interval=1`, `vm.dirty_writeback_centisecs=500`, THP `always`,
`psi=1`, `vm.swappiness=180` (pmOS zram default — keep), one timer only
(`systemd-tmpfiles-clean`, daily), listening: sshd:22, resolved stub :53,
LLMNR :5355.

## 2. Optimization catalog (customization only)

### A. Wakeup diet — `/etc/sysctl.d/10-alloy-idle.conf`

```ini
vm.stat_interval = 10
vm.dirty_writeback_centisecs = 6000
```

- `stat_interval=10`: stops per-CPU 1 s vmstat housekeeping → **≈ −3.5/s**
- `dirty_writeback` 5 s → 60 s: batches flusher churn; also the single best
  eMMC-friendly change for real Krane (fewer small writes)
- Expected: **25.0 → ~21.5 IRQ/s** measured

### B. Boot cmdline — `/boot/loader/entries/pmos.conf` (edit, not fork)

```
options console=tty1 console=ttyAMA0,115200
```

- drop `psi=1`: kills 5 psimon threads + PSI accounting → **−0.4–1/s**
- add `transparent_hugepage=madvise`: THP churn off by default →
  kcompactd 2.0/s → ~0, khugepaged 10 s scan stops → **−2/s**
- systemd degrades gracefully (oomd already masked; pressure telemetry lost —
  acceptable for the baseline, documented)
- Expected cumulative with A: **~19–20 IRQ/s**, i.e. *at the arch_timer floor*

### C. Enablement diet — D-Bus activation verified, so functionality survives

- `systemctl disable wpa_supplicant.service` — NM re-activates it via
  `fi.w1.wpa_supplicant1` (activation file verified) when a WiFi device
  appears. Krane WiFi unaffected. **−3.3–4.3 MiB RAM, 1 service**
- `systemctl disable rtkit-daemon.service` — pipewire re-activates via
  `org.freedesktop.RealtimeKit1` (file verified) when an audio session starts.
  Krane audio unaffected. **−1.4 MiB, 1 service**
- `apk-inhibit.service`: static, running, zero dependents — investigate its
  trigger (likely `apk` D-Bus side-channel); disable if `apk update/add`
  verifiably works without it. **−1.0 MiB, 1 service**
- Expected: **14 → 11–12 services, −5.7 MiB boot RAM** (measured with SSH
  probe; probe itself adds sshd-session+user@0 ≈ +10 MiB)

### D. Decision items (not executed by default)

- **journald `Storage=volatile`**: logs to /run (tmpfs) — saves eMMC writes on
  real Krane and the 8.5 MB persistent journal; loses post-crash logs. The
  10 MB cap already bounds it; volatile is the aggressive option.
- **`DefaultMemoryAccounting=no`**: micro-gain; costs the "Mem peak" data in
  journal records. Keep unless squeezing.
- **Direct-kernel boot (lab only)**: `run-qemu-headless.sh --direct` with
  `-kernel/-initrd` from the ESP skips EDK2's 5.5 s → **boot ~12.4 → ~6–7 s**.
  Lab measurement convenience only — real Krane goes through Depthcharge, so
  this is *not* a device claim.

### E. Measured as not-worth-it (leave alone)

- NM logging level, resolved LLMNR/MDNS (zero wakeups already), timesyncd poll
  (already backed off to 1024 s+), udevd `children_max` (boot-only effect),
  swappiness=180 (zram-correct), zram size (no idle cost), `sched_autogroup`
  (fine), getty@tty1 (0.6 MiB, console access is a keep-list item).

## 3. Proposed ALLOY-BASELINE-0004 = A + B + C

| Metric | 0003 | **0004 projected** |
|---|---|---|
| Idle wakeups | 22.8–25.0/s | **~19–20/s** (HVF floor) |
| Boot RAM | 105 MiB | **~99 MiB** |
| Services | 14 | **11–12** |
| Image | 714 MiB | ~712 MiB (configs only) |
| Boot → SSH | 12.4 s | unchanged (12.4 s) |

Everything above stays stock pmOS: sysctls, kernel cmdline flags, systemd
drop-ins and `systemctl disable` — all reverts are `apkless` (config files +
enablement), and each change is individually reversible.

---
*Profile measured 2026-09-08. On approval, 0004 executes A+B+C with the same
measurement battery (median-of-3 boots, idle host, ≥2 min settle).*
