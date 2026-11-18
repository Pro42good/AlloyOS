<img src="assets/Classic_Prime_Market.svg" width="112" alt="Alloy OS logo">

# Alloy OS

**A lightweight Linux OS for laptops and tablets, built on postmarketOS.**

[Build & test](#build-and-test) · [Duranium](#duranium-immutable-ab-updates) · [Performance](#desktop-performance-goals) · [Roadmap](#roadmap) · [Report an issue](https://github.com/Pro42good/AlloyOS/issues/new)

[![Development status](https://img.shields.io/badge/status-early%20development-orange?style=flat-square)](#project-status)
[![postmarketOS](https://img.shields.io/badge/base-postmarketOS-1d99f3?style=flat-square)](https://postmarketos.org)
[![License](https://img.shields.io/github/license/Pro42good/AlloyOS?style=flat-square)](LICENSE)

---

Alloy is being built for touch and keyboard, with web, native Linux, and
Android apps sharing one desktop. The idea is to start small, bring up app
runtimes when they're needed, and get those resources back when you're done.
The OS itself updates as an image, with a working slot available if the new
one fails to boot.

## Project status

| Area | Where it stands |
| --- | --- |
| **Alloy Core** | Measured headless aarch64 QEMU baseline with ZRAM and disk swap for overflow. [Core build and test tools](devices/kukui-krane/alloy/README.md) |
| **Duranium V1** | Signed installs, boot confirmation, fallback, and recovery demonstrated in a minimal UEFI/systemd-boot QEMU fixture. Full Core integration and hardware validation are ahead. |
| **Desktop** | The compositor, native diagnostic shell, app runtimes, and Chromium SystemUI are planned. [Roadmap](#roadmap) |

The Lenovo IdeaPad Duet (Krane) is an early test device. The QEMU lab uses
virtual hardware, and the Duet has a different boot chain and drivers.
[Krane lab](devices/kukui-krane/README.md) · [QEMU vs. Krane](devices/kukui-krane/docs/QEMU_VS_KRANE.md)

---

## Build and test

For the headless system, start with the Core build guide. It covers the image
recipe, development profiles, and the tests for system behavior and idle
activity. [Build Alloy Core](devices/kukui-krane/alloy/README.md)

Duranium’s separate QEMU fixture exercises normal updates, interrupted
installs, corrupt boot files, and recovery. The fixture tooling is on the
Duranium development branch.

---

## Duranium (immutable A/B updates)

If Alloy is running from slot A, Duranium verifies the signed update and writes
it to slot B. B gets a trial boot and becomes active after the OS passes its
health checks and marks the slot good. If B runs out of boot attempts, the
bootloader can return to A. Declared persistent data lives on a separate
`STATE` partition, and the recovery shell can repair or reinstall an OS slot.

APK is a build input for the host image. **MAI** is planned as the app installer
and dependency manager, while **MAC** will build and trim packages. One option
under consideration is letting MAI install existing `.apk` packages into an
isolated app environment with its own filesystem and package database.

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

---

## Roadmap

1. **System services.** Build `alloyd` and the services for sessions,
   permissions, hardware, resource management, health, and telemetry.
2. **App model and native desktop.** Define a shared app identity, build the
   compositor and diagnostic shell, then exercise input, display, suspend,
   audio, networking, and updates on real hardware.
3. **App compatibility and packages.** Build out ACR, add Android runtime
   integration, and develop MAI and MAC. Bring up optional runtimes when apps
   need them.
4. **Device tuning and SystemUI.** Use ASHT to tune policies with hardware
   measurements. Build SystemUI on stock Chromium and measure that workload
   before optimizing the browser for it.
5. **Everyday use.** Finish the desktop and software store, integrate Android
   apps into the shell, and harden updates, recovery, and factory reset.

## License

See [LICENSE](LICENSE) for the project and [asset licenses](assets/LICENSES/)
for artwork.
