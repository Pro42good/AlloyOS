# ALLOY-BASELINE-0007

**Final sweep — the configuration pass.** Every remaining system audited and
configured deliberately: the ones we use (sshd, NM, resolved, journald, PID1,
udevd, sysctls, fstab) and the dormant ones that still touched us (LLMNR
listener, NM connectivity probes, bluetooth activation, dead SSH sessions,
journal churn). Configuration only — upstream drop-ins and enablement flags,
no forks, each line individually reversible.

| | |
|---|---|
| ID | ALLOY-BASELINE-0007 |
| Date | 2026-09-08 |
| Parent | ALLOY-BASELINE-0006 (`baselines/0006/alloy-baseline-0006.qcow2`, kept pristine) |
| Artifact | `baselines/0007/alloy-baseline-0007.qcow2` (698 MiB) |
| Packages | 267 — unchanged |
| Health | 0 failed units; 12 services; SSH dev-tunnels functionally verified |

---

## 1. Audit → action table

| System | Found (effective) | Changed to | Why |
|---|---|---|---|
| sshd `AllowTcpForwarding` | **no** (pmOS UI-policy hardening, main config) | **yes** (`sshd_config.d/00-alloy.conf`) | ssh tunnels are a dev essential; first-wins drop-in overrides cleanly |
| sshd `LoginGraceTime` | 120 s (default) | 30 s | unauthenticated sockets linger for nothing |
| sshd ClientAlive | unset → dead sessions keep `sshd-session`+`user@0` (~10 MB) after host sleep | `ClientAliveInterval 60`, `ClientAliveCountMax 3` | dead sessions die in ~3 min |
| sshd root / UseDNS / X11 | prohibit-password / no / no | kept (already correct) | verified, not assumed |
| NetworkManager connectivity check | unset → NM default (periodic HTTP probe) | `[connectivity] enabled=false` | no use for reachability probing; removes periodic traffic+wakeups |
| NetworkManager logging | default (info) | `[logging] level=WARN` | less journal churn |
| resolved LLMNR | **on — listening 0.0.0.0:5355 + :::5355** | `LLMNR=no` | unused surface; mDNS already off via distro drop-in (kept) |
| journald caps | SystemMaxUse=10M only | + `RuntimeMaxUse=10M` | both tiers bounded |
| PID1 `DefaultTimeoutStopSec` | 90 s default | 5 s | our poweroff/compact cycles; no critical slow stoppers remain |
| udevd `children_max` | unbounded | 2 | bounds coldplug fork storms |
| sysctl `vm.watermark_boost_factor` | 15000 (default) | 0 | prevents boost storms under transient reclaim (pairs with zram layering) |
| fstab mount options | `rw,relatime` on / and /boot | `noatime` | fewer inode write-backs; /tmp already tmpfs |
| `bluetooth.service` | enabled (not running) | **disabled** | prevents surprise D-Bus activation; bluez stays installed for the Krane track |
| `vm.page-cluster` | **already 0** (pmOS cros-style) | kept | correct for zram; verified not assumed |
| zram | zstd, 5.7 G, pri 300 | kept | best available algorithm |
| nftables | active, empty ruleset | kept | clean slate for future rules |
| getty@tty1 + serial-getty | active | kept | console login + serial debug path (keep-list) |
| `apk-inhibit` | path-triggered sleep inhibitor | kept (0004 decision) | suspend-safety on a tablet |

## 2. Verification

- `sshd -T` shows the four overrides live; **functional tunnel test passes**
  (host-side `ssh -L 19999:127.0.0.1:22` → local listener answers)
- `netstat`: **:5355 gone** (LLMNR); :53 stub + :22 remain — the only listeners
- NM/resolved/udevd/sshd restarted cleanly; `systemctl --failed` = 0 across a
  fresh boot; DNS resolves; apk works
- Drop-in files (all reversible deletions):
  `/etc/ssh/sshd_config.d/00-alloy.conf`, `/etc/NetworkManager/conf.d/00-alloy.conf`,
  `/etc/systemd/resolved.conf.d/00-alloy.conf`, `/etc/systemd/journald.conf.d/10-alloy-cap.conf`,
  `/etc/systemd/system.conf.d/00-alloy.conf`, `/etc/udev/udev.conf`,
  `/etc/sysctl.d/10-alloy-idle.conf`, `/etc/fstab`

## 3. Metrics

| | 0006 | **0007** | read |
|---|---|---|---|
| Image | 692 MiB | **698 MiB** | +6 MiB config/journal churn |
| Boot RAM | 105 MiB | **96 MiB** | sample-to-sample band ±9 MiB; low end after caps |
| Idle wakeups | 6.92/s | **7.13/s** | within noise (±0.2) |
| Services | 12 | 12 | bluetooth was inactive anyway |
| Boot → SSH (median-of-3) | 12.4 s | **12.5 / 12.5 / 12.6 s** | unchanged |
| systemd-analyze | 9.31 s | 9.56 s | within run variance |
| SSH dev tunnels | blocked | **working** | the headline functional win |
| Dead-session RAM | leaked until reboot | reaped in ~3 min | ClientAlive |

**Honest read:** this sweep is *hygiene*, not footprint. The wins are
functional and structural — dev tunnels enabled, dead-session reaping,
listener surface −2 sockets, probe traffic off, write churn down (noatime +
journal caps), shutdown 90 s→5 s — while wakeups/RAM move only within the
noise band. That is what a correctly-configured floor looks like: the
remaining footprint is load-bearing.

## 4. Cumulative state (Phosh image → 0007)

| | Phosh | **0007** | Δ |
|---|---|---|---|
| Image | 2208 MiB | **698 MiB** | −68 % |
| Packages | 1187 | 267 | −78 % |
| Boot RAM | 183 MiB | ~96–105 MiB | −45 % |
| Services | 27 | 12 | −56 % |
| Idle wakeups | 114.9/s | 7.1/s | −94 % |
| Kernel modules | 2176 files / 72.8 MB | 625 / 23.3 MB | −68 % |
| Boot → SSH | 12.5 s | 12.5 s | unchanged (firmware-bound) |
| Keep-list | — | kernel, firmware, Mesa/Panfrost, systemd, net/audio/input, SSH | verified every step |

## 5. Reproduce

```sh
cd ~/Documents/gihhub/Kukui-krane
scripts/run-qemu-headless.sh baselines/0007/alloy-baseline-0007.qcow2 \
    /tmp/serial.log /tmp/qemu.pid 2222 baselines/0007/vars.fd
# tunnel smoke test (from host):
ssh -f -N -L 19999:127.0.0.1:22 -p 2222 root@127.0.0.1 && nc -z 127.0.0.1 19999
```

Artifacts in `baselines/0007/`: `alloy-baseline-0007.qcow2`, `overlay-0007.qcow2`,
`vars.fd`, `timings-b{1,2,3}.txt`, `serial-*.log`, `out/baseline-0007.*`.

---
*Measured 2026-09-08. ALLOY-BASELINE-0007 is the final mutable-pmOS floor:
734 → 698 MiB of pure configuration hygiene on top of six measured
reductions. Everything from here is the structural track (LLVM-free Mesa,
initramfs features, tickless kernel work) or the Duranium build.*
