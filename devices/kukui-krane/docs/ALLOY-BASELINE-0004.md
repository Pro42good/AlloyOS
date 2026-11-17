# ALLOY-BASELINE-0004

**Fourth measured reduction**: runtime tuning of the running set — sysctls,
kernel cmdline, and enablement only. No packages changed, no patches, no
forks: every change is a stock pmOS/Alpine/systemd/kernel configuration knob
and individually reversible.

| | |
|---|---|
| ID | ALLOY-BASELINE-0004 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0003 (`baselines/0003/alloy-baseline-0003.qcow2`, kept pristine) |
| Artifact | `baselines/0004/alloy-baseline-0004.qcow2` (719 MiB) |
| Packages | 267 — unchanged |
| Health | 0 failed units; 12 services; apk verified working |

---

## 1. Changes applied

### A. `/etc/sysctl.d/10-alloy-idle.conf`
```ini
vm.stat_interval = 10          # per-CPU vmstat housekeeping 1 s -> 10 s
vm.dirty_writeback_centisecs = 6000   # flusher churn 5 s -> 60 s
```

### B. `/boot/loader/entries/pmos.conf` (boot config edit, upstream params)
```
options console=tty1 console=ttyAMA0,115200 transparent_hugepage=madvise psi=0
```
- `psi=1` dropped, `psi=0` added — **discovery**: this kernel has PSI *enabled
  by default* (CONFIG), so pmOS's `psi=1` was redundant and merely *removing*
  it changed nothing (`/proc/pressure` persisted, 3 psimon monitors kept
  running). An explicit `psi=0` is required: psimon 3→0, `/proc/pressure` gone.
- `transparent_hugepage=madvise` — THP churn off by default (was `[always]`
  with khugepaged scanning every 10 s).
- Cost accepted and documented: PSI pressure telemetry is gone (oomd already
  masked; kernel OOM killer unaffected).

### C. Enablement (functionality preserved via D-Bus activation)
- `systemctl disable wpa_supplicant.service` — NM re-activates it through
  `fi.w1.wpa_supplicant1` (activation file intact) when a WiFi device appears.
- `systemctl disable rtkit-daemon.service` — pipewire re-activates via
  `org.freedesktop.RealtimeKit1` when an audio session starts.
- `apk-inhibit.service` — **evaluated and kept**: it is triggered by
  `apk-inhibit.path` (watches apk activity) and holds a sleep inhibitor during
  apk transactions — a real safety feature on a suspendable device like Krane,
  for 1 MiB.

### Verification performed
- `apk update` works with wpa/rtkit disabled
- cmdline live: `... transparent_hugepage=madvise psi=0`; THP reports `[madvise]`
- sysctls live: `stat_interval=10`, `dirty_writeback=6000`
- psimon = 0 across cold boot; wpa/rtkit inactive; 0 failed units; both gettys,
  udev, NM, resolved, timesyncd active
- input classification unaffected (event devices still tagged by `input_id`)

## 2. Metrics

| Metric | 0001 | 0002 | 0003 | **0004** | Δ 0003→0004 |
|---|---|---|---|---|---|
| Idle wakeups (60 s) | 28.1/s | 23.9/s | 22.8/s | **11.4/s** | **−50 %** |
| — arch_timer component | 19–20/s | — | 19.1/s | **9.6/s** | the floor moved |
| Boot RAM (used / available) | 107 / 3590 | 103 / 3594 | 105 / 3595 | **101 / 3600** | −4 MiB |
| Process count | 105 | 103 | 105 | **99** | −6 |
| Running services | 16 | 14 | 14 | **12** | −2 |
| Image size | 881 MiB | 754 MiB | 714 MiB | **719 MiB** | +5 (config + journal churn; trimmed) |
| Boot → SSH (median-of-3) | 12.9–15.9 s | 12.6 s | 12.4 s | **12.4 / 12.4 / 12.5 s** | unchanged |
| systemd-analyze | 9.48–11.72 s | 9.34 s | 9.28 s | **9.29 s** (fw 5.48 + loader 0.12 + kernel 1.25 + userspace 2.44) | unchanged |
| Packages / payload | 267 / 632 MB | — | — | 267 / 632 MB | unchanged |

Read: the wakeup collapse is bigger than projected (−50 % vs −15 % projected)
because the three housekeeping sources (vmstat 1 s per-CPU ticks, PSI
accounting/monitors, THP compaction) were each feeding the arch_timer rate —
remove all three and the guest's *demand* for timer ticks collapses, which
under HVF shows up directly in the arch_timer line. On real Krane hardware the
absolute numbers will differ, but the same three knobs govern the same
behavior (tickless kernel + no PSI + no THP churn).

## 3. Reverting any piece

```sh
# sysctls:  rm /etc/sysctl.d/10-alloy-idle.conf
# cmdline:  restore 'psi=1' / remove 'transparent_hugepage=madvise' in /boot/loader/entries/pmos.conf
# services: systemctl enable --now wpa_supplicant rtkit-daemon
```

## 4. Methodology notes

- **Shell trap**: `ps | grep -c psimon` counts the grep itself — always count
  via `/proc/*/comm` (this produced a false "PSI still alive" scare; the
  follow-up `/proc/pressure` check settled it).
- PSI is kernel-default-on in this build; `psi=0` is the only reliable off
  switch. Documented in §1-B.
- Journald RSS varies 14–23 MiB between boots depending on session logging
  (the measurement SSH itself); idle-without-SSH runs sit at the low end.
- Image grew 714 → 719 MiB from three extra boots of journal churn; vacuum +
  dual-fs trim applied before final compaction.

## 5. Remaining queue (unchanged structural tracks)

Profile-gated: none left (wpa/rtkit handled here; NM stays for Krane parity).
Structural: LLVM-free Mesa (−168 MB, pmaports), kernel-module prune (72→~22 MB),
initramfs features (15.3 MB), kernel config slimming, journald `Storage=volatile`
decision, lab-only direct-kernel boot mode (skips the 5.5 s EDK2 firmware stage).

## 6. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0004/alloy-baseline-0004.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0004/vars.fd
# median-of-3 timed boots + collect (idle host, ≥2 min settle):
baselines/0001/measure-boot.sh baselines/0004/alloy-baseline-0004.qcow2 \
    baselines/0004/serial-b3.log baselines/0004/timings-b3.txt 2222 \
    baselines/0004/vars.fd
baselines/0001/collect-metrics.sh <prefix> 60
```

Artifacts in `baselines/0004/`: `alloy-baseline-0004.qcow2`, `overlay-0004.qcow2`
(throwaway), `vars.fd`, `timings-b{1,2,3}.txt`, `serial-*.log`, `out/baseline-0004.*`.

---
*Measured 2026-09-08. Cumulative from the Phosh image: 2208 → 719 MiB (−67 %),
183 → 101 MiB boot RAM, 27 → 12 services, 114.9 → 11.4 IRQ/s idle (−90 %),
130 → 99 processes, boot steady at ~12.4 s spawn→SSH.*
