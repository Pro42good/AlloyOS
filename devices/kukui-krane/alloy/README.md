# ALLOY build program — Core, profiles, lineage, gates

Everything after ALLOY-BASELINE-0007 lives here. The floor is frozen; this
directory builds and gates everything on top of it.

## Lineages

| Lineage | Base | Status | Purpose |
|---|---|---|---|
| **ALLOY-GUI-0000** | `images/pmos-qemu-aarch64.qcow2` (2208 MiB, **frozen**) | immutable ancestor | the graphical QEMU baseline: Phosh on edge/systemd. UI experiments branch from here (GUI-0001+ = Phosh fixes), never from CORE. Boots via `scripts/run-pmos-vm.sh`. |
| **ALLOY-CORE** | derived from GUI-0000 by the seven measured steps | **frozen** at `baselines/0007/alloy-baseline-0007.qcow2` (698 MiB, sha256 in `baselines/0007/FROZEN.sha256`); rebuilt reproducibly as `alloy/core/alloy-core.qcow2` (604 MiB compressed) | the headless reference: kernel, firmware, Mesa/Panfrost, systemd, net/audio/input, SSH — nothing graphical |
| profiles | overlays/derivatives of CORE | current below | named deltas with their own artifacts |

Both frozen files carry the macOS **immutable flag** (`uchg`): QEMU cannot
open them read-write, so direct boots fail by design — everything derives via
overlay. To unfreeze deliberately: `chflags nouchg <file>`.

## Artifacts

```
alloy/core/alloy-core.qcow2          604 MiB (compressed) — rebuilt, gated
alloy/profiles/alloy-dev-0001.qcow2    + git build-base vim tmux htop strace python3 mandoc man-pages
alloy/profiles/alloy-prod-0001.qcow2   + key-only SSH, volatile journal, nftables firewall (oneshot unit)
alloy/profiles/alloy-lab-0001.qcow2    + python3 git tmux htop + ALLOY tooling baked to /opt/alloy
```

## Tooling

| Script | What it does |
|---|---|
| `build-core.sh [src] [out]` | pristine → CORE in 8 gated stages (00 keys/bootstrap → 07 configs), one convert per stage (chained overlays leak source residue into the flatten — see §gotchas), final artifact compressed; ends with both gates |
| `build-profile.sh <dev\|prod\|lab>` | CORE → profile artifact + both gates |
| `regression-test.sh <img> [profile]` | functional integrity: keep-list (20 pkgs), Panfrost file, config surface (cmdline/sysctl/sshd/journal), runtime (0 failed units, 8 critical services, swap layering, module footprint ≤700 files/≤30 MB, listeners = {22,53,53}, input classification via `--export-db`) |
| `quiescence-test.sh <img> [profile]` | idle behavior: boot ≤35 s, service count (exact 12 for core/prod), procs, boot RAM, **idle IRQ ≤12/s (core) — measured ~7.6/s**, idle CPU ≤1 %, idle writes ≤2 MB/60 s, listener set |
| `steps/00-keys.sh … 07-configs.sh` | the deterministic Core recipe (consolidated from the 0001–0007 records) |
| `keys/*.pub` | the apk trust ring, extracted from pmbootstrap — builds are self-contained |

Gates boot on throwaway overlays, so frozen inputs are legal everywhere.
`ssh-run.exp` (baselines/0001) handles the one password-bootstrap of a fresh
pristine boot.

## Gotchas (all paid for, all documented)

1. **Chained overlays lie**: `qcow2 rm` doesn't write LBAs — deleted-file
   regions read through to the backing chain, so a chained flatten carried
   ~800 MB of Phosh residue (1506 vs ~700 MiB). Fix: per-stage converts
   (implemented in `build-core.sh`) and/or zero-fill free space before the
   final convert. Compressed output (`-c`) is the canonical core packaging.
2. **`/etc/udev/udev.conf` does not exist on fresh images** — stage 07 guards
   for both states (the original 0007 had it).
3. **`grep -c` exits 1 on zero matches** — harness retries treat rc≠0 as
   connection failure; count via awk `n++ / END print n+0` or host-side.
4. **`netstat` lines end in `LISTEN`** — listener checks must parse the
   address column, not the line tail.
5. **`sshd -T` echoes option names in configured case** — match with `-i`.
6. **`udevadm info -q property <dev>` intermittently omits db tags** on this
   udev build; `--export-db` reads the db files directly and is reliable.
   Also: **never `udevadm trigger --action=change` on input subsystems** — it
   empties the runtime db and it does not self-heal (reboot recovers).
7. **Self-referential convert lock**: `qemu-img convert overlay.qcow2
   <overlay's-own-backing>` deadlocks — always flatten to a temp file, then
   `mv`.

## Validation record (2026-09-09)

- prod / dev / lab profiles: **REGRESSION ALL PASS + QUIESCENCE ALL PASS**
- full Core rebuild from pristine: 8 stages clean (one udev.conf hiccup,
  fixed in the step script and patched into the artifact), final artifact
  **REGRESSION ALL PASS + QUIESCENCE ALL PASS** (boot 10.4 s, 12 services,
  98 procs, 101 MiB RAM, 7.6 IRQ/s, 0.0 % CPU idle, 0 writes)
- frozen CORE (0007) and ALLOY-GUI-0000: sha256-locked, immutable-flagged
