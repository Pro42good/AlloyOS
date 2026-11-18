# Reproducibility — can the floor be rebuilt from this repo?

**Short answer: yes, in two scripted phases**, with three environment
dependencies that are logged (not hidden). This document is the audit trail
for that claim.

## Phase 1 — base image (upstream → bootable qcow2)

```sh
PMOS_PASS=… ./scripts/pmbootstrap-docker.sh base
# env: DEVICE=qemu-aarch64  UI=console  PMB_TAG=3.12.1  PMOS_USER=user
```

What it does, end to end:
1. Ensures the Docker build container (SYS_ADMIN + loop devices; no
   `--privileged`), installs pmbootstrap at the pinned tag (`PMB_TAG`).
2. Non-interactive `pmbootstrap init` (fresh pmaports from the edge channel),
   config device/UI/user/work.
3. `pmbootstrap install --password …` — phases 1–2 build the rootfs; phase 3
   fails at `/dev/loop0p2` **by design in Docker** (documented since 0001).
4. Manual disk assembly (ext4 rootfs with real fstab injected, FAT ESP with
   systemd-boot entry, GPT) and `qemu-img convert` to a host qcow2.
5. Prints the artifact path and sha256.

**Environment dependencies (recorded, not controlled):**
- pmaports moves (edge): the *procedure* is reproducible; an exact byte-level
  rebuild needs the pmaports commit recorded. The 1000/1001 build used
  pmaports @ `02c676b` (2026-11-17) → kernel 7.3.4, systemd 262.
- Docker image `ubuntu:24.04` floats (pinned only by tag).
- Kernel choice: the device package offers `stable` (7.3.4), `lts` (6.18.63),
  `mainline` (7.4-rc3); the build takes the device default unless changed in
  `pmbootstrap config`.

## Phase 2 — the ALLOY floor recipe (base qcow2 → floor)

```sh
BASE=console ./alloy/build-core.sh <base.qcow2> <out-floor.qcow2>
# BASE=console -> step 01-strip-nura (console/Nura bases: pin keep-list, drop
#                 GUI-era fonts/lang, add console keymaps, mask avahi)
# BASE=phosh   -> step 01-strip (the original 0001 cascade; tolerant of
#                 packages that are already absent)
```

Stages, all in `alloy/steps/`:
`00-keys` (apk trust) → strip → `02-filecuts` (boot files, var garbage,
journal caps, oomd/coredumpd masks) → `03-hwdb` (trie diet) → `04-tuning`
(sysctls, `psi=0`, THP=madvise, wpa/rtkit off) → `05-swap` (zram kept +
2 GB zeroed swapfile) → `06-modprune` (keep-rules for qemu-virt) →
`07-configs` (sshd/NM/resolved/journald/PID1/udev/noatime/avahi/console).

The driver boots each stage in an overlay of the previous artifact, runs the
stage over SSH (pinned host keys, env password only for first contact),
flattens per stage, then runs **both gates** on the result.

## Phase 3 — gates (the definition of "works")

```sh
VARS=baselines/<lineage>/vars.fd ./alloy/regression-test.sh <floor.qcow2> core-nura
VARS=baselines/<lineage>/vars.fd ./alloy/quiescence-test.sh <floor.qcow2> core-nura
```

`core-nura` thresholds: services ≤14, procs ≤120, boot RAM ≤140 MiB,
idle IRQ ≤12/s, idle CPU ≤1 %, idle writes ≤2 MB/60 s, boot ≤35 s,
listeners ⊆ {22, 53×2}.

## Freeze / provenance

```sh
./alloy/freeze.sh <artifact>     # sha256 manifest + uchg (macOS immutable)
```

## Known limits of the claim

1. **Not bit-reproducible**: package versions move with edge; pin pmaports
   (record the commit) for byte-level determinism.
2. **Docker for phase 1 only**: the floor recipe itself needs no container.
3. **macOS-specific bits**: `chflags uchg` (freeze), `shasum`, `expect`,
   HVF args in the runners. Linux hosts can substitute equivalents.
4. **Host tooling**: QEMU ≥8 (tested 11.1.1), EDK2 aarch64 firmware, a
   working `/usr/bin/expect`.
5. **The 435 MiB artifact is not in git** (GitHub file-size limit); its
   sha256 is committed. Rebuild it from phases 1–2, or attach it to a
   Release.

## Verification status

- Phase 2 was exercised end-to-end on the 7.3.4 base during the 1000/1001
  build (the deltas it exposed are merged back into the steps).
- **Gates re-run against the frozen 1001 artifact using only repo scripts**
  (`core-nura`, `VARS=baselines/1000/vars.fd`) — 2026-11-18:
  - **REGRESSION: ALL PASS** (20 keep-list packages, panfrost, config surface,
    runtime, swap layering, modules 638/21 MB, listeners {22,53×2}, input)
  - **QUIESCENCE: ALL PASS** — boot 15.9 s cold-cache (≤35), services 13 (≤14),
    procs 102 (≤120), RAM 105 MiB (≤140), failed 0, IRQ 8.42/s (≤12),
    CPU 0.01 %, writes 0.2 MB/60 s, listener set exact
  - Raw output: `baselines/1000/out/gates-1001.txt`
