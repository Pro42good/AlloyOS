# 14 — Visual atlas

[Back to docs index](README.md)

A single-page set of charts and maps for orientation. Detailed explanations
are in the linked chapters; this page is for seeing the shape of the system
quickly.

---

## 1. Project timeline

```mermaid
timeline
    title Alloy OS engineering timeline (recorded work)
    section 2026-09-08
      Krane research : Primary-source hardware verification
                     : Official google-kukui image verified and dissected
      GUI-0000       : pmbootstrap Phosh VM boots on Apple Silicon
      ALLOY 0001     : GUI stripped to 267 packages
      ALLOY 0002     : Boot/var cuts and blocked-deps map
      ALLOY 0003     : hwdb diet
      ALLOY 0004     : Runtime tuning, PSI/THP/compaction
      ALLOY 0005     : IRQ floor and swap layering
      ALLOY 0006     : Kernel-module diet
      ALLOY 0007     : Configuration sweep and freeze
    section 2026-09-09
      Security audits : Two audits plus remediation
      Core program    : Reproducible build, profiles, gates
    section 2026-11-17
      1000/1001       : New console base, kernel 7.3.4
      Duranium V1     : Unit and QEMU suites green
    section 2026-11-18
      This docs tree  : Repo-wide engineering guide
```

---

## 2. Component maturity

```mermaid
flowchart LR
    subgraph M4["Tested end to end"]
        Core["Core floor"]
        Gates["Regression + quiescence"]
        Dur["Duranium V1"]
        Rec["Recovery"]
        Lab["QEMU lab"]
    end
    subgraph M3["Implemented, partially integrated"]
        Profiles["dev/lab/prod"]
        Adapter["Duranium Core adapter"]
        Legacy["pmbootstrap path"]
    end
    subgraph M2["Placeholder files"]
        Brand["Plymouth / Fastfetch / KSM / Waydroid / Plasma"]
        Pkg["alloy-core APKBUILD"]
    end
    subgraph M1["Planned"]
        Alloyd["alloyd"]
        Comp["Compositor"]
        UI["SystemUI"]
        Eco["MAI / MAC / ACR / Android / ASHT"]
    end
    M4 --> M3 --> M2 --> M1
```

---

## 3. Repository dependency map

```mermaid
flowchart TB
    Setup["scripts/setup.sh"]
    CoreBuild["alloy/build-core.sh"]
    Profile["alloy/build-profile.sh"]
    Gates["regression + quiescence"]
    Runners["run-qemu-headless.sh<br/>run-pmos-vm.sh"]
    DurUnit["tests/run-unit.sh"]
    DurSuite["tests/qemu/run-suite.sh"]
    Fix["qemu/build-fixture.sh"]
    Artifact["qcow2 artifacts"]
    Fixture["fixture + testdata"]
    Docs["docs/ (this tree)"]

    Setup --> CoreBuild
    Setup --> DurUnit
    Setup --> DurSuite
    Setup --> Runners
    CoreBuild --> Runners
    CoreBuild --> Gates
    CoreBuild --> Artifact
    Profile --> Gates
    Profile --> Artifact
    Fix --> Fixture
    DurSuite --> Fixture
    DurSuite --> Runners
    Artifact -->|"kernel + systemd-boot"| Fix
    CoreBuild -.->|"documented by"| Docs
    DurSuite -.->|"documented by"| Docs
```

---

## 4. Layer stack

```mermaid
flowchart TB
    L8["Alloy desktop (planned)<br/>SystemUI, apps, notifications, store"]
    L7["System services (planned)<br/>alloyd, identity, lifecycle, telemetry"]
    L6["Compatibility (planned)<br/>ACR, Android runtime"]
    L5["Packaging (planned)<br/>MAI, MAC, ASHT"]
    L4["Update + recovery (working)<br/>Duranium"]
    L3["Base OS (working)<br/>Alloy Core floor"]
    L2["Distribution<br/>postmarketOS / Alpine / systemd"]
    L1["Hardware<br/>QEMU virt now, Krane later"]

    L8 --> L7 --> L6 --> L5 --> L4 --> L3 --> L2 --> L1
```

Only layers 1–4 are implemented to any degree; 5–8 are roadmap.

---

## 5. Floor metrics dashboard

### Image size (MiB)

```mermaid
xychart-beta
    title "qcow2 image size"
    x-axis ["Phosh", "0001", "0002", "0003", "0004", "0005", "0006", "0007", "1001"]
    y-axis "MiB" 0 --> 2300
    bar [2208, 881, 754, 714, 719, 734, 692, 698, 435]
```

### Boot RAM (MiB)

```mermaid
xychart-beta
    title "RAM used after boot"
    x-axis ["Phosh", "0001", "0002", "0003", "0004", "0005", "0006", "0007", "1001"]
    y-axis "MiB" 0 --> 200
    line [183, 107, 103, 105, 101, 98, 105, 96, 106]
```

### Idle wakeups (IRQ/s)

```mermaid
xychart-beta
    title "Idle interrupt rate"
    x-axis ["Phosh", "0001", "0002", "0003", "0004", "0005", "0006", "0007", "1001"]
    y-axis "IRQ/s" 0 --> 120
    line [114.9, 28.1, 23.9, 22.8, 11.4, 8.73, 6.92, 7.13, 9.32]
```

### Services and boot time

```mermaid
xychart-beta
    title "Services at idle"
    x-axis ["Phosh", "0001", "0002", "0003", "0004", "0005", "0006", "0007", "1001"]
    y-axis "Services" 0 --> 30
    bar [27, 16, 14, 14, 12, 12, 12, 12, 13]
```

```mermaid
xychart-beta
    title "Boot spawn → SSH (seconds)"
    x-axis ["Phosh", "0001", "0002", "0003", "0004", "0005", "0006", "0007", "1001"]
    y-axis "Seconds" 0 --> 18
    line [12.5, 12.9, 12.6, 12.4, 12.4, 12.4, 12.4, 12.5, 12.5]
```

---

## 6. Where boot time goes

```mermaid
pie showData
    title "1001 guest boot — 9.504 s"
    "EDK2 firmware" : 5.483
    "systemd-boot" : 0.192
    "Kernel" : 1.255
    "Userspace" : 2.573
```

---

## 7. Duranium test coverage

### Unit checks by area (167 total)

```mermaid
xychart-beta
    title "Duranium unit assertions"
    x-axis ["metadata", "selection", "manifest", "mark-good", "update", "state", "recovery", "profiles", "policy"]
    y-axis "Checks" 0 --> 40
    bar [17, 17, 14, 18, 35, 27, 24, 12, 3]
```

### QEMU assertions by scenario (176 total)

```mermaid
xychart-beta
    title "Duranium QEMU assertions"
    x-axis ["acceptance", "failures", "rec-both", "rec-a", "rec-mixed", "corrupt-boot"]
    y-axis "Assertions" 0 --> 80
    bar [72, 29, 19, 19, 21, 16]
```

| Scenario | Boots |
| --- | --- |
| acceptance | 9 |
| failures | 2 |
| recovery-both | 2 |
| recovery-a | 2 |
| recovery-mixed | 3 |
| corrupt-boot | 5 |
| **Total** | **23** |

---

## 8. Data ownership at a glance

```mermaid
flowchart LR
    subgraph Boot["BOOT — boot-critical"]
        B1["systemd-boot"]
        B2["per-slot kernels"]
        B3["entries + counters"]
        B4["slot/global metadata"]
    end
    subgraph State["STATE — persistent"]
        S1["home"]
        S2["etc/alloy"]
        S3["var/lib/alloy"]
        S4["caches + logs"]
        S5["schema, bootlog, backups"]
    end
    subgraph Tmp["tmpfs — per boot"]
        T1["/run/duranium/boot.env"]
        T2["/tmp, /var/tmp"]
    end
    subgraph Slots["SYSTEM_A/B — read-only"]
        A1["OS image"]
        A2["image-owned defaults"]
    end
    Boot -->|"selects"| Slots
    State -->|"binds"| Slots
    Tmp -->|"flags"| Boot
    State -.->|"never affects"| Boot
```

---

## 9. Roadmap phases

```mermaid
flowchart TB
    P1["Phase 1<br/>Headless OS platform<br/>Duranium, alloyd, identity,<br/>resources, telemetry, memory, health"]
    P2["Phase 2<br/>Hardware + normal services<br/>input, power, storage, network,<br/>audio, BT, update service"]
    P3["Phase 3<br/>App definition<br/>app model, lifecycle, notifications"]
    P4["Phase 4<br/>Graphics<br/>compositor, integration, motion,<br/>native diagnostic shell"]
    P5["Phase 5<br/>App runtimes<br/>ACR, lazy XWayland, Waydroid"]
    P6["Phase 6<br/>App/package infrastructure<br/>MAI, MAC"]
    P7["Phase 7<br/>ASHT<br/>real tuning"]
    P8["Phase 8<br/>Chromium<br/>stock, SystemUI MVP, optimize, final"]
    P9["Phase 9<br/>Deep integration<br/>Android UX, wallpaper, AI, store, hardening"]

    P1 --> P2 --> P3 --> P4 --> P5 --> P6 --> P7 --> P8 --> P9
```

### Krane checkpoints

```mermaid
flowchart LR
    P2["Phase 2"] --> C1["Krane #1<br/>hardware basics"]
    P4["Phase 4"] --> C2["Krane #2<br/>native graphical OS"]
    P7["Phase 7"] --> C3["Krane #3<br/>real ASHT tuning"]
    C1 --> P3["Phase 3"]
    C2 --> P5["Phase 5"]
    C3 --> P8["Phase 8"]
```

### The measurement boundary

```mermaid
flowchart LR
    Native["Native diagnostic shell<br/>Alloy-only cost"] --> Measure["Measure Alloy<br/>RAM, CPU, IRQ, quiescence"]
    Measure --> Stock["Stock Chromium"]
    Stock --> MVP["SystemUI MVP<br/>real workload"]
    MVP --> Optimize["Alloy Chromium optimization"]
```

This is the central sequencing rule: **no Chromium until Alloy is already a
usable graphical OS, and no Chromium optimization until the SystemUI workload
exists to measure.**

---

## 10. The one-screen mental model

```mermaid
flowchart TB
    K["Krane hardware<br/>MT8183, Mali, ath10k"] -.->|"cannot run in QEMU"| Q["QEMU virt lab"]
    Q --> C["Alloy Core<br/>small, measured, headless"]
    C --> P["Profiles<br/>dev / lab / prod"]
    C --> D["Duranium<br/>A/B, signed, recoverable"]
    D --> A["alloyd<br/>IPC, identity, resources,<br/>telemetry, memory, health"]
    A --> H["Hardware services<br/>input, power, storage,<br/>network, audio, BT"]
    H --> M["App model + compositor<br/>lifecycle, windows, notifications"]
    M --> N["Native diagnostic desktop<br/>Alloy without Chromium"]
    N --> R["App runtimes<br/>ACR, XWayland, Waydroid"]
    R --> PK["MAI / MAC"]
    PK --> S["ASHT<br/>tuning"]
    S --> U["Chromium SystemUI<br/>then final desktop"]
    G["Gates + measurements"] --- C
    G --- P
    T["Duranium tests"] --- D
```

The repository today is the lower-left portion of this picture plus the
measurement rig. Everything from `alloyd` upward is the roadmap.
