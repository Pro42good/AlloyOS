# ALLOY-BASELINE-1000 / 1001 — new base, newer kernel

**The experiment:** take a *brand-new* upstream image (fresh pmbootstrap 3.12.1
+ pmaports @ 2026-11-17, kernel **7.3.4**, systemd 262) and see whether the
ALLOY recipe applies unchanged. Result: **it does**, with four small
adaptations recorded below.

| | |
|---|---|
| 1000 — pristine new base | `alloy-1000-base.qcow2` — 898 MiB, sha256 `e3bde225…` |
| 1001 — floor applied | `alloy-1001-floor.qcow2` — **435 MiB** (compressed), sha256 `0586afc5…` |
| Source | pmbootstrap 3.12.1 (updated from 3.11.1), pmaports master 2026-11-17 |
| Device / UI / kernel | `qemu-aarch64` / `console` / linux-postmarketos-stable **7.3.4** |
| Distinct base | **"Nura edge"** (the distro's current name), 361 packages |

## What the new base looked like (before)

- 361 packages, console UI, systemd 262, kernel 7.3.4
- Already-running: avahi, rtkit, wpa_supplicant, oomd, coredumpd, LLMNR :5355
- Missing for the floor: mesa/panfrost, pipewire/ALSA, libinput pins; empty apk keyring; no console keymaps
- 113 processes, 120 MiB RAM, 2243 module files / 66.9 MB

## Recipe delta (what did NOT carry over cleanly)

| Issue | Fix (now in `alloy/steps/`) |
|---|---|
| New base ships the same **empty apk keyring** | keys scp'd from `alloy/keys/` (same fix as 0001) |
| Console base has **no console keymaps** → vconsole failure | `01-strip-nura.sh` adds `kbd-bkeymaps`; `07` writes `KEYMAP=us` |
| `apk del` list contains packages the console base never had, `userdel` names may not exist | tolerant filters/`|| true` in 01/02 |
| 7.3.4 autoloads **`i2c_dev`** — keep-rules dropped it | `drivers/i2c/*` added to keep-rules in 06 |
| **avahi is a hard dep of `postmarketos-ui-console`/`alsa-utils`** (old floor lost it as a phosh orphan) | disable + mask (installed-but-dormant), −1.0 IRQ/s |
| `sudo` on the new image requires a **TTY** | `ssh-run.exp` spawns `ssh -t` (committed) |

Everything else applied verbatim: keep-list pins, hwdb diet (13.5 MB → 292 KB),
sysctls (`stat_interval=10`, `compaction_proactiveness=0`, `watermark_boost=0`),
boot cmdline (`psi=0`, `THP=madvise`), zram+swapfile layering, module prune,
config sweep (sshd forwarding off / LLMNR off / NM probes off / journal caps /
PID1 5 s / udev children_max / noatime).

## Results — old floor vs new floor

| Metric | 0007 (7.2.4) | **1001 (7.3.4)** | Δ |
|---|---|---|---|
| Boot → SSH (median-of-3) | 12.4 s | **12.4 / 12.4 / 12.4 s** | **identical** |
| Boot RAM | 96–105 MiB | **113 MiB** | +8–17 |
| Processes | ~100 | **103** | +3 |
| Services | 12 | **13** (avahi masked, console-UI plumbing) | +1 |
| Idle wakeups | 6.9–7.1/s | **8.67/s** (9.70 before avahi mask) | +1.6–1.8 |
| Kernel modules | 625 / 21.9 MB | **638 / 21.4 MB** | +13 files |
| Image (compressed) | 349 MiB (rebuilt core) | **435 MiB** | +86 |
| Panfrost `panfrost_dri.so` | ✅ | ✅ | — |
| LLMNR listener | off | **off** (:22, :53×2 only) | — |
| Failed units | 0 | **0** | — |

**Read:** the recipe transfers; the small deltas are *base* differences, not
recipe regressions — a console-UI base carries slightly more (avahi, console
plumbing, systemd 262) and its kernel module set is 7.3.4's. Boot time is
identical because it is firmware-dominated (EDK2 5.5 s) on both.

## Verification

- `uname -r` → 7.3.4; cmdline `…transparent_hugepage=madvise psi=0`; THP `[madvise]`
- sysctls live; listeners only :22/:53×2; panfrost present; zram+swapfile layered
- `systemctl --failed` → 0; services list stable; module resolution proof passed
  (`loaded-module resolution: OK` after the i2c fix)
- New SSH host keys pinned via the recorded ceremony (old + new keys coexist in
  `alloy/known_hosts`, fingerprints in the header)

## Reproduce

```sh
# in pmb-kukui-lab: pmbootstrap 3.12.1, device qemu-aarch64, ui console,
# kernel stable; pmbootstrap install --password … (fails at loop0p2 by design)
# manual assembly (fixup path) -> convert to qcow2 -> boot
# then run:  alloy/steps/01-strip-nura.sh 02 03 04 05 06 07
# gates:     alloy/regression-test.sh <img> core-nura
#            alloy/quiescence-test.sh <img> core-nura
```

Artifacts live in `~/dev/alloy-local/baselines/1000/` (local staging; the repo
copy in Drive stays cloud-only until explicitly hydrated).

---
*Built and measured 2026-11-17. Recipe applied end-to-end in one session;
every deviation from the 0007 lineage is listed in §"Recipe delta".*
