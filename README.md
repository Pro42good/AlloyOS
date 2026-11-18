<div align="center">
  <a href="https://github.com/Pro42good/AlloyOS"><img src="assets/Classic_Prime_Market.svg" alt="Alloy OS (codename: Classic Prime Market)" width="200"></a>
  <h1>Alloy OS</h1>
  <p>A lightweight Linux OS for laptops and tablets, built on postmarketOS.</p>

[![License](https://img.shields.io/github/license/Pro42good/AlloyOS?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/Pro42good/AlloyOS?style=flat-square)](https://github.com/Pro42good/AlloyOS/commits/main)
[![Development](https://img.shields.io/badge/status-early_development-orange?style=flat-square)](https://github.com/Pro42good/AlloyOS)
[![postmarketOS](https://img.shields.io/badge/base-postmarketOS-1d99f3?style=flat-square)](https://postmarketos.org)

</div>

Alloy is meant to be a full desktop you can use with a keyboard or a
touchscreen. It starts with a small Linux base, brings up runtimes as apps need
them, and aims to give those resources back once you're done. The Lenovo
IdeaPad Duet (Krane) is a test device for that design. [Krane lab notes](devices/kukui-krane/README.md)

## What works today

- **Alloy Core** has a measured headless aarch64 QEMU baseline. Build 1001
  recorded **113 MiB of RAM at boot** and **8.67 idle wakeups per second**. The
  baseline also uses ZRAM with a disk swapfile for overflow. [Baseline notes](devices/kukui-krane/docs/ALLOY-BASELINE-1000-1001.md)

## Duranium (immutable A/B updates)

Duranium V1 is in development. The current prototype has demonstrated signed
offline updates, boot confirmation, fallback, and recovery in a minimal
UEFI/systemd-boot QEMU fixture. Full Alloy Core integration and testing on
physical hardware are still ahead.

If you're running from slot A, Duranium installs the signed OS image into slot B
and leaves A ready to boot. B gets a trial boot and becomes the active slot
after it passes the health checks and is marked good. If B uses up its boot
attempts, the bootloader can return to A. A separate `STATE` partition holds
declared persistent data across updates and rollbacks, and a recovery shell can
repair or reinstall a system slot.

APK is a build input for the host image. The plan is for **MAI** to install apps
and manage their dependencies, while **MAC** builds and trims packages. One
option under consideration is for MAI to install existing `.apk` packages into
an isolated runtime with its own filesystem and package database.

## Roadmap

1. Build `alloyd` and the system services for identity, permissions, app
   lifecycle, resource management, telemetry, health, and hardware.
2. Define a shared app identity for web, native Linux, and Android apps.
   Build the Wayland compositor and a small native diagnostic desktop around
   it. Test input, suspend, audio, networking, and updates on real hardware.
3. Add ACR for Linux app compatibility, bring up XWayland and Waydroid on
   demand, and build out MAI and MAC.
4. Use ASHT to tune policies from real hardware measurements. Build SystemUI
   on stock Chromium and measure the actual shell workload before tuning
   Chromium for it.
5. Finish the touch and keyboard desktop, integrate Android apps into the
   shell and store, and harden updates, recovery, and factory reset for
   everyday use.

## Desktop performance goals

The finished desktop should settle back to **25 or fewer running services**
and **under 100 interrupts per second** at idle, with low CPU use measured
separately. **Around 200 MiB of idle RAM** is a stretch goal, including the RAM
that ZRAM actually occupies.

The test is to use the desktop, close the apps, and see how far CPU and memory
drop again. The native diagnostic desktop gives us a measurement before
Chromium SystemUI enters the picture. Stock ChromeOS and stock postmarketOS on
the same Duet are planned comparison points.
