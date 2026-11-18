# AlloyOS — device: kukui-krane

Working package of the ALLOY program for the Lenovo IdeaPad Duet ("Krane",
MT8183 / kukui): the measured postmarketOS floor, its recipe, its harnesses,
and **one compiled baseline image**. This directory is self-contained except
for QEMU and a macOS host.

## Contents

```
docs/                          every baseline record, packet, lineage, history,
                               operations manual, security audits
scripts/                       QEMU runners (gui/headless/arm), pmbootstrap
                               base-image pipeline (`base` command), image
                               downloader (pinned sha256)
alloy/
  steps/                       the deterministic floor recipe
                               00-keys, 01-strip(-nura), 02-filecuts, 03-hwdb,
                               04-tuning, 05-swap, 06-modprune, 07-configs
  profiles/                    dev / prod / lab deltas
  build-core.sh                reproducible base -> floor build (8 stages,
                               BASE=phosh|console)
  freeze.sh                    sha256 manifest + macOS immutable flag
  build-profile.sh             floor -> profile artifacts
  regression-test.sh           functional-integrity gate
  quiescence-test.sh           idle-behavior gate (incl. `core-nura` profile)
  keys/                        apk signing keys (public) + provenance/rotation
  known_hosts                  pinned SSH host keys + fingerprints
baselines/
  0001..0007/                  measurement harnesses + per-step evidence
                               (no VM images — see lineage docs)
  1000/                        ★ the compiled baseline
    alloy-1001-floor.qcow2       435 MiB, sha256 0586afc5…a7cc (frozen, uchg)
    vars.fd                      UEFI NVRAM (regenerable: 64 MiB zeros)
    FROZEN-1000-1001.sha256      pinned hashes (1000 base not shipped here)
```

## What the compiled baseline is

`ALLOY-BASELINE-1001` — the ALLOY floor applied to a **brand-new** upstream
build (pmbootstrap 3.12.1, pmaports 2026-11-17, device `qemu-aarch64`, UI
`console`, kernel **7.3.4**, systemd 262, base self-identifying as
"Nura edge"). Kept: kernel, firmware, Mesa + **Panfrost**, systemd, network/
audio/input, SSH. No GUI.

| Metric | Value |
|---|---|
| Boot → SSH (median-of-3) | 12.4 s (firmware-dominated) |
| Boot RAM | 113 MiB |
| Processes / services | 103 / 13 (`avahi` installed-but-masked) |
| Idle wakeups | 8.67 IRQ/s |
| Kernel modules | 638 files / 21.4 MB |
| Artifact | 435 MiB compressed qcow2 |

Full record: `docs/ALLOY-BASELINE-1000-1001.md` (recipe deltas vs the 0007
lineage included). **Reproducibility audit: `docs/ALLOY-REPRODUCIBILITY.md`** (what is scripted,
what depends on the environment, how to rebuild). **Performance record:
`docs/ALLOY-PERF-1001.md`**
(boot phases, RAM, services, IRQ breakdown, per-process wakeups, storage,
host-side cost, and the side-by-side vs the 7.2.4 lineage). Older lineage (kernel 7.2.4, Phosh ancestry):
`docs/ALLOY-BASELINE-000{1..7}.md`, `docs/ALLOY-PACKET-0000-to-0007.md`.

## Boot it

```sh
# sandbox copy (never boot the frozen file directly — uchg blocks it by design)
qemu-img create -f qcow2 -F qcow2 \
  -b baselines/1000/alloy-1001-floor.qcow2 /tmp/krane-sandbox.qcow2
./scripts/run-alloy-gui.sh /tmp/krane-sandbox.qcow2     # cocoa window, console login
# or headless:
./scripts/run-qemu-headless.sh /tmp/krane-sandbox.qcow2 /tmp/serial.log /tmp/qemu.pid 2222 baselines/1000/vars.fd
# login: user / 147147   (SSH localhost:2222; root key-auth)
```

Gates (boot their own throwaway overlays):

```sh
./alloy/regression-test.sh <img> core-nura
./alloy/quiescence-test.sh <img> core-nura
```

## Trust

- Artifact hash pinned in `baselines/1000/FROZEN-1000-1001.sha256`
- SSH host keys pinned in `alloy/known_hosts` (fingerprints in header,
  re-pinning ceremony in `docs/ALLOY-OPERATIONS.md` §10)
- apk trust anchors in `alloy/keys/` (public keys; provenance + rotation
  documented there)
- Two security audits completed with remediation records:
  `SECURITY_AUDIT_2026-09-09.md`, `SECURITY_AUDIT_2026-09-09_1554.md`

## Caveat: this tree lives inside Google Drive

Drive may keep large files cloud-only (`dataless`); QEMU cannot read those.
If a boot fails with `Operation timed out` on the qcow2, open it once in
Finder ("Available offline") or copy it to a non-synced path and boot there.
The recommended layout is a **local working copy** with Drive as archive.

---
*Lineage: ALLOY-GUI-0000 → 0001..0007 (kernel 7.2.4) → 1000/1001 (kernel 7.3.4,
new base). Everything in this package was executed and measured; every
deviation is documented.*
