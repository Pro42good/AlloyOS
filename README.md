<div align="center">
  <img src="assets/Classic_Prime_Market.svg" alt="Alloy OS (codename: Classic Prime Market)" width="200">
  <h1>Alloy OS</h1>
  <p><strong>A lightweight Linux OS for laptops and tablets, built on postmarketOS.</strong></p>
  <p>
    <a href="INSTALL.md">Build &amp; use</a> ·
    <a href="#whats-in-the-repo">Components</a> ·
    <a href="#desktop-performance-goals">Performance</a> ·
    <a href="#roadmap">Roadmap</a> ·
    <a href="#project-status">Status</a> ·
    <a href="https://github.com/Pro42good/AlloyOS/issues/new">Report an issue</a>
  </p>
  <p>
    <a href="#project-status"><img src="https://img.shields.io/badge/status-early%20development-orange?style=flat-square" alt="Early development"></a>
    <a href="https://postmarketos.org"><img src="https://img.shields.io/badge/base-postmarketOS-1d99f3?style=flat-square" alt="Built on postmarketOS"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/Pro42good/AlloyOS?style=flat-square" alt="License"></a>
  </p>
</div>

---

Alloy is being built for touch and keyboard, with web, native Linux, and
Android apps sharing one desktop. The idea is to start small, bring up app
runtimes when they're needed, and get those resources back when you're done.
The system image has its own update and recovery path.

## Build and use

Start with the [installation guide](INSTALL.md). It covers building Alloy Core,
booting it in QEMU, and testing the update and recovery fixture from a Duranium development checkout. The same setup
script runs each workflow.

```sh
./scripts/setup.sh --help
```

## What's in the repo

- **Alloy Core** is the measured postmarketOS base. The build recipe trims the
  image, configures ZRAM and disk swap, and checks that the result boots and
  settles at idle. The lab also has dev, lab, and prod profile recipes.
  [Core build tools](devices/kukui-krane/alloy/README.md)
- **Duranium** verifies a signed OS image, stages it in the inactive A/B slot,
  then confirms the new boot or falls back. A separate `STATE` partition holds
  declared persistent data, and the recovery environment can repair or
  reinstall a slot. The prototype is on the Duranium development branch.
- **The device lab** keeps the QEMU build and measurement tooling together.
  The Lenovo IdeaPad Duet (Krane) is an early test device. Its boot chain and
  drivers differ from QEMU's virtual hardware.
  [Krane lab](devices/kukui-krane/README.md) · [QEMU vs. Krane](devices/kukui-krane/docs/QEMU_VS_KRANE.md)
- **Branding and earlier prototypes** include the boot theme, Fastfetch
  artwork and configuration, wallpaper, memory and Android configuration
  experiments, and an older desktop conversion script.
  [Boot theme](boot/plymouth/) · [Configuration files](configs/) · [Artwork](assets/)

APK is a build input for the host image. The app layer will use **MAI** for
installs and dependencies and **MAC** to build and trim packages. Installing
existing `.apk` packages into an isolated app environment is an option under
consideration.

## Desktop performance goals

The headless Alloy 1001 QEMU image recorded **113 MiB of RAM at boot** and
**8.67 idle wakeups per second**. [Baseline measurements](devices/kukui-krane/docs/ALLOY-BASELINE-1000-1001.md)

| Metric | Goal for the finished desktop |
| --- | --- |
| Running services at idle | 25 or fewer |
| Interrupts at idle | Under 100 per second |
| CPU at idle | Low sustained use, measured separately from interrupts |
| RAM at idle | Around 200 MiB as a stretch goal, counting the RAM used by ZRAM |

The test is to use the desktop, close the apps, and measure where CPU and memory
settle. The native diagnostic shell gives us a baseline before Chromium enters
the picture. Stock ChromeOS and postmarketOS on the same Duet are planned
comparison points.

## Roadmap

### System foundation

1. [x] **Duranium V1 prototype.** Exercise signed images, A/B slots, boot confirmation, rollback, migrations, and recovery in QEMU.
2. [ ] **`alloyd`.** Build the daemon, versioned IPC, events, and service registry.
3. [ ] **Identity and permissions.** Define users, sessions, caller identity, and secrets.
4. [ ] **Resource and lifecycle management.** Track foreground and background work, apply cgroup policies, and support freezing and discarding apps.
5. [ ] **Telemetry.** Attribute CPU, memory, I/O, and wakeups to apps or services, and measure time to idle.
6. [ ] **Memory-pressure policy.** Coordinate ZRAM, swap, reclaim, and foreground protection.
7. [ ] **System health.** Handle crash loops, restart budgets, degraded operation, and recovery hooks.

### Hardware and services

8. [ ] **Device and input.** Bring up hotplug, keyboards, touchpads, and touchscreens.
9. [ ] **Power and display.** Add brightness, suspend, wake, inhibitors, battery state, and thermal hooks.
10. [ ] **Storage.** Manage mounts, removable devices, persistent app data, caches, and disk pressure.
11. [ ] **Networking.** Expose connection state, Wi-Fi, Ethernet, DNS, and airplane mode.
12. [ ] **Audio.** Integrate PipeWire and WirePlumber, including per-app streams and idle suspension.
13. [ ] **Bluetooth.** Support pairing, trust, audio, and on-demand activation.
14. [ ] **Duranium update service.** Integrate staging, reboot, and health reporting with Alloy Core. Validate updates and basic hardware on a physical device.

### Apps and graphics

15. [ ] **Unified app model.** Define app identity, permissions, storage, and how windows attach to apps.
16. [ ] **App lifecycle service.** Discover, launch, freeze, resume, and stop apps by identity.
17. [ ] **Notifications.** Add ownership, actions, history, and Do Not Disturb.
18. [ ] **Compositor.** Build display, input, focus, window management, and idle-aware frame scheduling.
19. [ ] **Window and app integration.** Connect visibility and focus to app identity and resource policy.
20. [ ] **Motion and gestures.** Share animation state and stop scheduling frames when idle.
21. [ ] **Native diagnostic desktop.** Bring up basic desktop controls and validate display, touch, suspend, and frame pacing on hardware.

### Compatibility, packaging, and tuning

22. [ ] **ACR.** Define the compatibility environment for native Linux apps.
23. [ ] **Legacy app compatibility.** Bring up optional runtime support on demand.
24. [ ] **Android runtime.** Connect app discovery, launch, windows, audio, and lifecycle.
25. [ ] **MAI.** Install apps, track dependencies, and reclaim unused packages.
26. [ ] **MAC.** Build packages with the features and dependencies Alloy needs.
27. [ ] **ASHT.** Benchmark on real hardware, choose device policies, and support reverting tuning changes.

### SystemUI and finishing work

28. [ ] **Stock Chromium.** Integrate browser windows and web apps with Alloy's lifecycle and accounting.
29. [ ] **SystemUI prototype.** Build the launcher, shelf, overview, and quick settings on stock Chromium.
30. [ ] **Chromium tuning.** Measure the actual shell workload, then tune memory, timers, and graphics.
31. [ ] **SystemUI.** Finish the touch and keyboard desktop, settings, login, lock screen, and accessibility.
32. [ ] **Android desktop integration.** Fit Android apps into Alloy's notifications, permissions, and settings.
33. [ ] **Wallpaper and media.** Add power-aware animation and stop work when the display is off.
34. [ ] **Local AI.** Add optional, on-demand tools to the launcher, settings, and diagnostics.
35. [ ] **Software store.** Present web, native, and Android apps through one install experience.
36. [ ] **Release hardening.** Finish verified boot, recovery, key rotation, factory reset, and production profiles.

## Project status

| Component | Status | What works in this checkout |
| --- | --- | --- |
| Alloy Core | Measured in QEMU | Headless image, SSH, ZRAM with disk swap, and functional and idle checks. [Core notes](devices/kukui-krane/alloy/README.md) |
| Duranium | QEMU prototype | Signed installs, boot confirmation, fallback, and recovery in a minimal fixture. Core integration and physical hardware tests are open. Prototype tooling is on the Duranium development branch. |
| Device lab | Available | ARM VM runners, image tooling, and the Krane hardware comparison. [Lab guide](devices/kukui-krane/README.md) |
| Branding and configs | Files in tree | Plymouth theme source, Fastfetch config, wallpaper, and experimental system settings. App and desktop integration are separate work. [Assets](assets/) · [Configs](configs/) |
| `alloyd`, compositor, and SystemUI | Planned | The native diagnostic desktop comes before the Chromium shell. |
| ACR, MAI, MAC, Android integration, and ASHT | Planned | These are later app compatibility, packaging, and device tuning milestones. |

[Project license](LICENSE) · [Artwork licenses](assets/LICENSES/)
