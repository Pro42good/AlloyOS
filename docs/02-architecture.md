# 02 — Architecture

[Back to docs index](README.md)

This document describes the system at three scales:

1. the **repository architecture** (what depends on what),
2. the **runtime architecture** of a booted Alloy image,
3. the **wiring** between build tools, artifacts, tests, and QEMU.

For step-by-step flows see [Boot flows](07-boot-flows.md) and
[Data flows](08-data-flows.md). For subsystem detail see
[Alloy Core](05-alloy-core-image.md) and
[Duranium](06-duranium-update-system.md).

---

## 1. Repository architecture

The repository is best understood as two products sharing one lab.

```mermaid
flowchart TB
    subgraph Entry["Entry points"]
        Setup["scripts/setup.sh<br/>public build/run facade"]
        Install["scripts/install.sh<br/>legacy in-place experiment"]
    end

    subgraph Lab["devices/kukui-krane — device lab"]
        LabDocs["docs/ — provenance, packets, audits"]
        LabScripts["scripts/ — QEMU, pmbootstrap, Krane image"]
        Alloy["alloy/ — Core recipe, profiles, gates"]
        Baselines["baselines/ — artifacts, harnesses, metrics"]
    end

    subgraph Packages["pkgs/"]
        Dur["duranium/ — update/recovery product"]
        CorePkg["alloy-core/ — empty APKBUILD"]
        ThemePkg["alloy-theme/, alloy-config/ — placeholders"]
    end

    subgraph Brand["assets/, boot/, configs/, themes/"]
        Assets["logo, wallpaper, licenses"]
        Placeholders["Plymouth, Fastfetch, KSM, Waydroid, Plasma<br/>empty files"]
    end

    Setup --> LabScripts
    Setup --> Alloy
    Setup --> Dur
    Alloy --> Baselines
    Alloy --> LabScripts
    Dur --> LabScripts
    Dur --> Baselines
    Install -.->|"not used by setup.sh"| Lab
    Baselines -->|"kernel + systemd-boot"| Dur
    CorePkg -.->|"intended packaging"| Alloy
    ThemePkg -.-> Brand
    Brand -.->|"not consumed by the floor"| Alloy
```

### Dependency rules visible in the code

- `scripts/setup.sh` is the only top-level orchestrator. It shells out to:
  - `devices/kukui-krane/alloy/build-core.sh` (`core-build`),
  - `devices/kukui-krane/scripts/run-pmos-vm.sh` (`core-run`),
  - `pkgs/duranium/tests/run-unit.sh` and `tests/qemu/run-suite.sh`
    (`duranium-test`),
  - `pkgs/duranium/qemu/build-fixture.sh` and `qemu/run-vm.sh`
    (`duranium-shell`).
- The Core build depends on the lab's QEMU runner and measurement helpers.
- Duranium's fixture builder reads **only the kernel and systemd-boot EFI
  binary** from the Core baseline image. It does not modify or embed Core.
- The Core build does **not** depend on Duranium. The two products are
  deliberately decoupled; only the documented adapter would integrate them.

### What is not wired

- `pkgs/alloy-core/APKBUILD` is empty; Core is built by shell assembly, not
  by APK packaging.
- Brand assets are not copied into any image builder.
- `configs/*` are empty placeholders.
- No CI workflow exists (`.github/` contains only `.gitkeep`).

---

## 2. Runtime architecture — Alloy Core

A booted Core image is a conventional postmarketOS system with a deliberately
small service set.

```mermaid
flowchart TB
    subgraph HW["Virtual hardware — QEMU virt"]
        CPU["4 vCPU, HVF host"]
        RAM["4 GiB RAM"]
        BLK["virtio-blk<br/>GPT qcow2"]
        NET["virtio-net<br/>127.0.0.1:2222 → :22"]
        IN["xhci + usb-kbd/tablet"]
        FW["EDK2 pflash + 64 MiB NVRAM"]
    end

    subgraph Boot["Boot chain"]
        UEFI["EDK2 UEFI"]
        SB["systemd-boot<br/>loader/entries/pmos.conf"]
        K["Linux 7.2.4 / 7.3.4"]
        INIT["postmarketOS initramfs<br/>stage 1 + 2"]
    end

    subgraph Root["Read-write rootfs — ext4"]
        Systemd["systemd PID 1"]
        NM["NetworkManager + resolved<br/>+ timesyncd"]
        SSH["sshd"]
        Audio["PipeWire / WirePlumber<br/>D-Bus activated"]
        Getty["getty@tty1<br/>serial-getty@ttyAMA0"]
    end

    subgraph Kernel["Kernel services"]
        Zram["zram0 zstd, pri 300"]
        Swap["/swapfile 2 GiB, pri 10"]
        Mods["pruned modules<br/>638 files / ~21 MB"]
        HWDB["compiled hwdb<br/>~288 KB"]
    end

    FW --> UEFI --> SB --> K --> INIT --> Systemd
    Systemd --> NM & SSH & Audio & Getty
    BLK --> INIT
    NET --> NM
    IN --> Systemd
    Zram --- Systemd
    Swap --- Systemd
    Mods --- K
    HWDB --- Systemd
```

### Core's architectural characteristics

- **One mutable root filesystem.** Core is not itself an A/B system; it is
  the artifact Duranium is meant to eventually wrap.
- **No graphics stack.** Phosh, greetd, Plymouth, GNOME apps, Firefox, and
  Flatpak are removed. Console login is the interface.
- **Immutable-ish only by convention.** The root is writable; updates happen
  by rebuilding images, not by `apk upgrade` on a production system.
- **Zram first, disk swap second.** Compression is the primary memory
  extension; the swapfile is overflow insurance.
- **Frozen artifacts are protected with macOS `uchg`.** They cannot be opened
  read-write by QEMU; every boot derives a qcow2 overlay.

---

## 3. Runtime architecture — Duranium

Duranium replaces "one mutable root" with five logical areas and a strict
state machine.

```mermaid
flowchart TB
    subgraph Disk["GPT disk"]
        BOOT["BOOT — FAT32<br/>systemd-boot, per-slot kernels,<br/>entries, metadata"]
        REC["RECOVERY — ext4<br/>independent CLI userland"]
        A["SYSTEM_A — ext4<br/>immutable image, read-only"]
        B["SYSTEM_B — ext4<br/>immutable image, read-only"]
        STATE["STATE — ext4<br/>persistent data + schema"]
    end

    subgraph Runtime["Running normal slot"]
        I["Per-slot initramfs<br/>verify + mount"]
        R["Root filesystem<br/>read-only"]
        S["STATE binds<br/>/home, /etc/alloy, /var/lib/alloy,<br/>/var/cache, /var/log"]
        T["tmpfs<br/>/run, /tmp, /var/tmp"]
        C["duranium CLI<br/>status, update, mark-good,<br/>boot-confirm, reconcile"]
    end

    subgraph Recovery["Recovery slot"]
        RI["Recovery initramfs"]
        RU["Recovery init<br/>CLI-only"]
        RC["inspect, repair-boot,<br/>reinstall, select,<br/>factory-reset"]
    end

    BOOT --> I
    A --> I
    I --> R
    I --> S
    STATE --> S
    I --> T
    R --> C
    BOOT --> C
    BOOT --> RI
    REC --> RI
    RI --> RU --> RC
```

### Component responsibilities

| Component | File(s) | Responsibility |
| --- | --- | --- |
| CLI | `src/bin/duranium` | Single entry point for normal, initramfs, recovery, tests |
| Common | `src/lib/common.sh` | Token validation, hashing, atomic writes, mount helpers, boot ID |
| Config | `src/lib/config.sh` | Loads image-owned config; validates attempts; exposes paths |
| Backend | `src/lib/backend.sh` | Maps logical areas to block devices or test directories |
| Metadata | `src/lib/metadata.sh` | Canonical slot/global records, checksums, dual copies, locking |
| Bootloader | `src/lib/bootloader.sh` | systemd-boot entries, boot counting, fake backend |
| Slot control | `src/lib/slot.sh` | Boot recording, reconciliation, mark-good/bad, selection |
| Manifest | `src/lib/manifest.sh` | Canonical manifest, Ed25519 verify/sign, payload hashing |
| Updater | `src/lib/update.sh` | Inactive-slot write, verification, transaction, locks |
| STATE | `src/lib/state.sh` | Allowlist parsing, bind mounts, schema, migrations |
| Health | `src/lib/health.sh` | Root/STATE/core/service gates for mark-good |
| Recovery | `src/lib/recovery.sh` | Inspect, repair, select, reinstall, reset |
| Initramfs | `src/lib/initramfs.sh` | Per-slot mount and `switch_root` |

### Backend abstraction

Core logic never hardcodes `/dev/vdaN`.

```mermaid
flowchart LR
    Logic["Metadata, state, update,<br/>recovery, selection"] --> Areas["Logical areas:<br/>A, B, STATE,<br/>RECOVERY, BOOT"]
    Areas --> Block["block backend<br/>GPT labels or explicit devices"]
    Areas --> Dir["dir backend<br/>files/directories"]
    Areas --> BootInt["bootloader interface"]
    BootInt --> SDB["systemd-boot"]
    BootInt --> Fake["fake boot counting<br/>(unit tests)"]
    BootInt -.->|"future"| Other["U-Boot / Depthcharge /<br/>other EFI manager"]
```

This is why the same shell code runs in the normal system, initramfs,
recovery, and test fixture.

---

## 4. Build and test wiring

```mermaid
flowchart LR
    subgraph Host
        Setup["setup.sh"]
        CoreBuild["build-core.sh"]
        RunHeadless["run-qemu-headless.sh"]
        Gates["regression-test.sh<br/>quiescence-test.sh"]
        Unit["tests/run-unit.sh"]
        Suite["tests/qemu/run-suite.sh"]
        FixBuild["build-fixture.sh"]
        RunVM["run-vm.sh"]
    end

    subgraph Docker
        Alpine["aarch64 Alpine<br/>fs tools"]
        PmOS["Ubuntu + pmbootstrap<br/>(legacy rebuild)"]
    end

    subgraph Artifacts
        Base["pristine/console base"]
        CoreImg["alloy-core.qcow2"]
        Fixture["duranium-fixture.img<br/>testdata.img"]
    end

    Setup --> CoreBuild
    Setup --> Unit
    Setup --> Suite
    Setup --> RunVM
    Base --> CoreBuild
    CoreBuild --> RunHeadless
    CoreBuild --> Gates
    CoreBuild --> CoreImg
    FixBuild --> Alpine
    Alpine --> Fixture
    Suite --> RunVM
    RunVM --> Fixture
    Unit --> Alpine
    CoreImg -->|"kernel + BOOTAA64.EFI"| FixBuild
    PmOS -.->|"legacy image construction"| Base
```

### Fixed QEMU geometry

All measured Core runs use the same geometry so numbers are comparable:

```
-M virt,highmem=on
-accel hvf -cpu host          # macOS/Apple Silicon
-smp 4
-m 4096
EDK2 pflash code + per-run 64 MiB NVRAM vars
virtio-blk (qcow2, discard=unmap)
virtio-net usermode NAT, hostfwd tcp:127.0.0.1:2222-:22
qemu-xhci + usb-kbd + usb-tablet
no display device (headless), serial to socket/logfile
```

The Duranium fixture uses a narrower variant:

```
-M virt,highmem=on
2 vCPU, 1024 MiB default
raw GPT disk + optional read-only test-data disk
fresh NVRAM per boot
-no-reboot
serial to logfile or stdio
HVF → KVM → TCG fallback
```

---

## 5. Trust architecture

```mermaid
flowchart TB
    subgraph Untrusted["Potentially untrusted"]
        Net["Network / downloaded image"]
        Art["Update artifact directory"]
        SD["STATE contents"]
    end

    subgraph Anchors["Pinned trust anchors"]
        PinnedSHA["Pinned image SHA-256"]
        Keys["/etc/duranium/keys/KEY.pub"]
        HostKeys["alloy/known_hosts"]
        ApkKeys["alloy/keys/*.pub"]
    end

    subgraph Verified["Verified before use"]
        Manifest["Canonical manifest<br/>+ Ed25519 signature"]
        Payload["system.img<br/>SHA-256 + read-back"]
        Boot["vmlinuz + initramfs<br/>SHA-256"]
        Meta["Slot/global metadata<br/>SHA-256 + strict schema"]
    end

    Net --> PinnedSHA
    Art --> Manifest
    Keys --> Manifest
    Manifest --> Payload & Boot
    Art --> Payload & Boot
    HostKeys --> BuildSSH["Build/test SSH"]
    ApkKeys --> Apk["apk package verification"]
    Meta --> Selection["Boot selection"]
    SD -.->|"never boot-critical"| Selection
```

Key boundaries:

- **BOOT is trusted boot-critical storage.** Metadata checksums are integrity
  checks, not signatures; root on a running system can alter them.
- **STATE is not boot-critical.** Corrupt or missing STATE cannot change slot
  selection, but it can fail `mark-good`.
- **Recovery does not depend on A/B or STATE.** It needs BOOT and RECOVERY
  only.
- **systemd-boot is a single point of failure** in V1; it is not A/B
  duplicated.

See [Security model](11-security-model.md) for the complete threat and audit
record.

---

## 6. Architectural invariants

These are the rules the code is built to preserve. Violating one is a bug.

### Alloy Core

1. The pristine source image is never written.
2. Every measured state is an overlay; delivered artifacts are flattened
   copies.
3. No forks or patches; every reduction is reversible configuration or a
   documented file cut.
4. Artifacts above the floor must pass both gates.

### Duranium

1. The running slot's filesystem is read-only and never written by an update.
2. Every update writes only the inactive slot.
3. The target is marked `UNKNOWN` before the first destructive write.
4. A slot becomes `PENDING` only after signature, payload, boot-artifact, and
   read-back verification.
5. A pending slot is preferred until its attempts run out.
6. `GOOD` requires explicit `mark-good` passing health checks.
7. Failed or unconfirmed slots become `BAD` and are not retried
   automatically.
8. Boot-critical metadata lives on BOOT, not STATE.
9. STATE is separate and survives updates, rollbacks, and reinstalls.
10. Only declared STATE paths persist.
11. A pending update must not make an irreversible STATE change while
    rollback is expected.
12. Recovery does not depend on either normal slot.

---

## 7. How the pieces would eventually connect

The documented target architecture (not implemented) is:

```mermaid
flowchart TB
    Alloyd["alloyd<br/>IPC, service registry,<br/>resource policy"] --> Apps["App lifecycle<br/>web / native / Android"]
    Comp["Compositor<br/>display, input, focus"] --> UI["SystemUI<br/>launcher, shelf, settings"]
    Alloyd --> Comp
    Duranium["Duranium update service"] --> Core["Immutable Core image"]
    Core --> Alloyd
    MAI["MAI package manager"] --> Apps
    MAC["MAC package builder"] --> MAI
    ACR["ACR compatibility"] --> Apps
    ASHT["ASHT tuning"] --> Alloyd
    UI --> Alloyd
```

Today, only the lower-left path — Core image plus Duranium — exists and is
tested. The rest is roadmap in [13-roadmap-and-glossary.md](13-roadmap-and-glossary.md).
