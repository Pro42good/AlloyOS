# 03 — Repository map

[Back to docs index](README.md)

Every top-level area, what it contains, how it is used, and what is only a
placeholder. Line counts are approximate and refer to this checkout on
2026-11-18.

---

## Top-level tree

```
AlloyOS/
├── README.md                  project narrative and roadmap
├── INSTALL.md                 build/boot instructions
├── LICENSE                    MIT (code) — assets have separate licenses
├── .gitignore                 excludes VM images, logs, out/
├── .github/                   empty (.gitkeep only)
├── assets/                    real logo, wallpaper, asset licenses
├── boot/                      Plymouth theme — empty placeholder files
├── configs/                   Fastfetch/KSM/Waydroid — empty placeholders
├── devices/kukui-krane/       the device lab (largest docs area)
├── pkgs/                      Duranium implementation + package placeholders
├── scripts/                   setup.sh facade + legacy install.sh
├── themes/                    Plasma look-and-feel — empty placeholder
└── docs/                      this engineering documentation
```

---

## `README.md`

The user-facing project description: mission, repository components,
performance goals, a 36-item roadmap, project status table, and license
links.

Notable content:

- Performance goals: ≤25 services, <100 IRQ/s, ~200 MiB RAM at idle.
- Headline measured baseline: 113 MiB RAM at boot, 8.67 idle wakeups/s
  (the 1001 line).
- Status table distinguishing "measured in QEMU", "QEMU prototype",
  "files in tree", and "planned".

## `INSTALL.md`

Concrete host instructions:

- Apple Silicon macOS with aarch64 QEMU/HVF.
- Docker for Duranium fixture construction.
- Python 3, Expect, OpenSSH, an Ed25519 key.
- A bootable postmarketOS `qemu-aarch64` qcow2 outside git.
- The four `scripts/setup.sh` commands and their prerequisites.

## `scripts/`

| File | Lines | Purpose |
| --- | --- | --- |
| `setup.sh` | ~139 | Public facade. Validates tools/env, then dispatches `core-build`, `core-run`, `duranium-test`, `duranium-shell`. |
| `install.sh` | ~303 | **Legacy experiment.** In-place conversion script for an already-installed postmarketOS aarch64 system toward a KDE Plasma desktop. Not used by `setup.sh`. Multiple sections are comments only. |

`setup.sh` environment variables:

| Variable | Meaning |
| --- | --- |
| `BASE` | `phosh` (default) or `console` for Core build |
| `PMOS_PASS` | Required guest password for Core build |
| `VARS` | Optional EDK2 NVRAM store |
| `PMOS_SSH_PORT` | `core-run` SSH forwarding, or `off` |
| `DURANIUM_EDK2_CODE` | Override EDK2 firmware path |
| `DURANIUM_BASELINE` | Directory containing `alloy-1001-floor.qcow2` |
| `DURANIUM_KERNEL`, `DURANIUM_EFI_BOOT` | Explicit kernel / systemd-boot files |
| `QEMU_SYSTEM_AARCH64` | Alternative QEMU binary |

## `devices/kukui-krane/`

The device lab. Self-contained except for QEMU and macOS.

| Path | Contents |
| --- | --- |
| `README.md` | 693-line lab manual: Krane research, two-track architecture, what the VM can/cannot do, known issues, build pipeline, troubleshooting |
| `INDEX.md` | Compact package index of the lab |
| `MOVED_TO_DRIVE.md` | Notes that large images were moved to Google Drive and symlinked |
| `SECURITY_AUDIT_2026-09-09.md` | First audit + remediation record |
| `SECURITY_AUDIT_2026-09-09_1554.md` | Second audit + remediation record |
| `docs/` | Baseline records, packet, history, operations, performance, Krane specs |
| `scripts/` | QEMU runners, pmbootstrap pipeline, image downloader |
| `alloy/` | Core recipe, profiles, gates, keys, known_hosts |
| `baselines/` | Measurement harnesses and evidence; one shipped 1001 image |

### `devices/kukui-krane/docs/`

| File | What it records |
| --- | --- |
| `ALLOY-PACKET-0000-to-0007.md` | The complete floor story: every step, metric, failure, revert |
| `ALLOY-BASELINE-0001.md` … `-0007.md` | Per-step primary evidence |
| `ALLOY-BASELINE-1000-1001.md` | Reapplying the recipe to a newer base (kernel 7.3.4) |
| `ALLOY-PERF-1001.md` | Formal performance record for 1001 |
| `ALLOY-PROCEDURE-0001-to-0005.md` | Chronological build commands and traps |
| `ALLOY-PROFILE-0004-RUNTIME.md` | Per-process idle profile and tuning catalog |
| `ALLOY-GUI-LINEAGE.md` | Frozen graphical ancestor and lineage rules |
| `ALLOY-HISTORY-AND-SACRIFICES.md` | Decision ledger and complete sacrifice ledger |
| `ALLOY-OPERATIONS.md` | Day-2 manual for the floor |
| `KRANE_SPECS.md` | Krane hardware → QEMU mapping |
| `QEMU_VS_KRANE.md` | Verified comparison, what transfers |

### `devices/kukui-krane/scripts/`

| Script | Purpose |
| --- | --- |
| `run-pmos-vm.sh` | Boot the Phosh VM in `gui`, `headless`, or `serial` mode |
| `run-qemu-headless.sh` | Daemonized measured boot with serial log + pidfile |
| `run-alloy-gui.sh` | Cocoa window + virtio-gpu for the headless floor |
| `run-qemu-arm.sh` | Deprecated reference runner |
| `download-kukui.sh` | Download official Krane image, verify pinned SHA-256 |
| `get-edk2.sh` | Check Homebrew EDK2 firmware |
| `pmbootstrap-docker.sh` | Legacy pmbootstrap build pipeline (`setup`, `fixup`, `shell`) |

### `devices/kukui-krane/alloy/`

| Path | Purpose |
| --- | --- |
| `README.md` | Lineages, artifacts, tooling, gotchas, validation record |
| `build-core.sh` | Pristine → Core in 8 gated stages |
| `build-profile.sh` | Core → dev/lab/prod artifact + gates |
| `regression-test.sh` | Functional-integrity gate |
| `quiescence-test.sh` | Idle-behavior gate |
| `steps/00-keys.sh` … `07-configs.sh` | Deterministic Core recipe |
| `profiles/dev.sh`, `lab.sh`, `prod.sh` | Profile deltas |
| `keys/` | 19 public APK signing keys + provenance/rotation README |
| `known_hosts` | Pinned guest SSH host keys + fingerprints |

### `devices/kukui-krane/baselines/`

```
baselines/
├── 0001/  measurement harnesses (measure-boot, collect-metrics, wakeups,
│          ssh-run.exp, guest digs) + timings
├── 0002/  timings
├── 0003/  guest profiler + timings
├── 0004/  timings
├── 0005/  offload demos + timings
├── 0006/  module-prune script + timings
├── 0007/  freeze manifests, gui pid, timings
└── 1000/  ★ the shipped frozen floor
    ├── alloy-1001-floor.qcow2     435 MiB, sha256-pinned
    ├── FROZEN-1000-1001.sha256
    └── out/                       gates + performance evidence
```

Only `1000/alloy-1001-floor.qcow2` is shipped in this checkout. The older
`alloy-baseline-000N.qcow2` files, the Phosh source image, and profile images
are referenced by scripts and docs but are not present (moved to Google Drive
or archived outside git). `.gitignore` excludes `*.qcow2`, `*.raw`, `*.img`,
`*.fd`, `*.log`, and `out/`.

## `pkgs/`

| Path | State | Notes |
| --- | --- | --- |
| `pkgs/duranium/` | **Fully implemented** | CLI, libraries, initramfs, recovery, tests, docs, QEMU fixture |
| `pkgs/alloy-core/APKBUILD` | **Empty (0 bytes)** | Intended package recipe; nothing is built from it |
| `pkgs/alloy-theme/` | Placeholder | `.gitkeep` only |
| `pkgs/alloy-config/` | Placeholder | `.gitkeep` only |

### `pkgs/duranium/`

```
pkgs/duranium/
├── APKBUILD                    Alpine package recipe (installs runtime + docs)
├── Makefile                    test / fixture / syntax / install targets
├── README.md                   V1 overview and quick start
├── src/
│   ├── bin/duranium            CLI dispatch
│   ├── lib/                    12 POSIX-shell libraries
│   ├── etc/                    runtime config, STATE allowlist, health hooks
│   ├── initramfs/init          initramfs PID 1
│   ├── recovery/init           recovery PID 1
│   ├── root/sbin-init          fixture slot PID 1
│   └── migrations/             example 1→2 additive migration
├── qemu/
│   ├── build-fixture.sh        host-side Docker orchestration
│   ├── build-in-container.sh   actual image construction
│   ├── run-vm.sh               one-boot QEMU runner
│   ├── guest-agent.sh          phase-driven test agent
│   └── out/                    generated artifacts (gitignored, ~17 GB here)
├── tests/
│   ├── run-unit.sh             runs unit scripts locally or in Docker
│   ├── unit/                   9 test scripts + shared lib
│   └── qemu/                   6 integration scenarios + runner
├── contrib/alloy-core/         systemd units + health adapter (reference)
└── docs/                       13 specifications, markers, limitations
```

## `assets/`

| File | Notes |
| --- | --- |
| `Classic_Prime_Market.svg` | Project logo (1 KB) |
| `wallpaper_default.jpg` | Real wallpaper (~3.5 MB) |
| `LICENSES/ASSET-LICENSE-CPM.markdown` | License for the Classic Prime Market artwork |
| `LICENSES/ASSET-LICENSE-WD.markdown` | License for the wallpaper/other artwork |
| `icons/` | Empty (`.gitkeep`) |

## Placeholders (empty files)

These exist as paths only. They are important to know about because the README
and directory names imply functionality that is not present.

| File | Intended role |
| --- | --- |
| `boot/plymouth/alloyos.plymouth` | Plymouth theme descriptor |
| `boot/plymouth/alloyos.script` | Plymouth boot animation script |
| `configs/fastfetch/config.jsonc` | Fastfetch layout |
| `configs/fastfetch/alloy_logo.txt` | Fastfetch ASCII logo |
| `configs/ksm/alloy-memory.conf` | KSM/memory tuning config |
| `configs/waydroid/waydroid_settings.conf` | Waydroid settings |
| `themes/plasma/look-and-feel/com.alloyos.prime.classic/metadata.desktop` | Plasma look-and-feel metadata |
| `pkgs/alloy-core/APKBUILD` | Core package build recipe |

The `themes/.../contents/layouts/` and `contents/splash/` directories also
contain only `.gitkeep`.

## `.github/`

Empty. There is no CI, release workflow, or issue template in this checkout.

## `.gitignore`

```
*.qcow2
*.raw
*.img
*.img.xz
*.iso
*.fd
*.log
.DS_Store
out/
```

This is why the QEMU fixtures, test logs, and VM images in
`pkgs/duranium/qemu/out/` are untracked even though they exist locally.

## What a fresh clone contains vs. what the docs describe

| Described by docs/scripts | Present in a fresh clone? |
| --- | --- |
| Core build scripts and recipe | Yes |
| Duranium source and tests | Yes |
| Duranium fixture builder | Yes |
| `alloy-1001-floor.qcow2` (435 MiB) | Yes, unless Git LFS/large-file policy removed it |
| Phosh source image | No |
| 0001–0007 qcow2 artifacts | No |
| Core/profile built images | No |
| QEMU run logs and fixture images | No (gitignored) |
| APK keys, known_hosts | Yes |

When a documented command fails because an image is missing, the cause is
almost always this table, not a broken script.
