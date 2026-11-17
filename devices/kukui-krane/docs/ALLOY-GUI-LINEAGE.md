# ALLOY graphical QEMU baseline lineage

**ALLOY-GUI-0000** is the frozen ancestor of the whole ALLOY line: the
ordinary mutable postmarketOS image (edge / Phosh / systemd, `qemu-aarch64`)
built by pmbootstrap + manual disk assembly (lab README §12).

| | |
|---|---|
| Artifact | `images/pmos-qemu-aarch64.qcow2` — 2208 MiB (2208.44 MiB), **frozen** |
| sha256 | `34d36a93efb3400ab95bd66d259e5340f7a9ff9d195bfd38a8d46c8924b20ca4` (`baselines/0007/FROZEN-GUI0000.sha256`) |
| Immutable flag | macOS `uchg` — direct boots fail by design; derive via overlay |
| Boot | `scripts/run-pmos-vm.sh` (gui / headless / serial) — boots to Phosh, SSH `localhost:2222`, `user`/`147147` |
| Contents | postmarketOS edge, linux-stable 7.2.4, Phosh + greetd + plymouth, firefox-esr, GNOME mobile apps, flatpak, GStreamer — the full UI stack (1187 pkgs, 27 services, 114.9 IRQ/s idle) |

## Lineage rules

```
ALLOY-GUI-0000 (Phosh, frozen)
├── ALLOY-CORE (headless floor)  ← the seven measured steps (0001–0007)
│     ├── alloy-dev-0001
│     ├── alloy-prod-0001
│     └── alloy-lab-0001
└── ALLOY-GUI-0001+ (future UI experiments branch HERE, never from CORE —
    re-adding Phosh onto the stripped floor is not a supported path)
```

- The **CORE** (frozen at `baselines/0007/`, rebuilt reproducibly at
  `alloy/core/`) is the headless reference; its record is the ALLOY packet.
- **GUI experiments** (Phosh tweaks, UI-level fixes for the eventual Krane
  build) branch from GUI-0000 as `ALLOY-GUI-000N` overlays, keeping the UI
  stack's provenance clean.
- What transfers between lineages: userspace/workflow knowledge only. Kernel/
  driver work needs the real Krane device (see `docs/QEMU_VS_KRANE.md`).

## Frozen CORE reference

| | |
|---|---|
| Artifact | `baselines/0007/alloy-baseline-0007.qcow2` — 698 MiB, **frozen** |
| sha256 | `03966db2f8caff03517c667ded9fb38f715248dee540812472ee07ce1abac702` (`baselines/0007/FROZEN.sha256`) |
| Rebuilt equivalent | `alloy/core/alloy-core.qcow2` — 604 MiB (compressed), gated |
