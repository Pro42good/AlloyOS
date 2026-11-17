# Duranium V1

Duranium is the immutable system-image and A/B update foundation for Alloy OS.
V1 proves one central property:

> **The currently working Alloy system is never sacrificed to perform an
> update.**

This tree is self-contained and does not modify the frozen Alloy Core build.
It is written in POSIX shell so the same code runs in the normal system, the
initramfs, the recovery environment, and the QEMU test fixture.

## What exists in V1

- GPT layout with `BOOT`, `RECOVERY`, `SYSTEM_A`, `SYSTEM_B`, `STATE`.
- Per-slot kernel and initramfs, written only to the inactive slot.
- systemd-boot boot counting as the QEMU/UEFI boot-attempt backend.
- Strict, dual-copy slot and global metadata on BOOT.
- Explicit `duranium mark-good`; booting a pending slot is not confirmation.
- Offline, signed update artifacts (SHA-256 + Ed25519).
- Separate persistent STATE with an explicit path allowlist.
- Versioned STATE schema with rollback-safe migration rules.
- Independent CLI-only recovery environment.
- Dev/lab/prod image identity checks.
- Automated unit and QEMU integration suites.
- Documentation of every format, invariant, result, and limitation.

## Layout

```
pkgs/duranium/
  src/bin/duranium        CLI
  src/lib/                metadata, manifest, updater, state, recovery, boot
  src/etc/                runtime config, STATE allowlist, health hooks
  src/initramfs/          PID 1 for per-slot boot
  src/recovery/           recovery PID 1
  src/root/sbin-init      deterministic fixture slot init
  src/migrations/         example additive schema migration
  qemu/                   fixture builder and one-boot runner
  tests/unit/             shell unit tests (run under Alpine)
  tests/qemu/             multi-boot integration scenarios
  docs/                   specifications and test results
  contrib/alloy-core/     example systemd units and health adapter
```

## Quick start (QEMU)

Prerequisites on the development host:

- QEMU with aarch64 `virt` and EDK2 (`/opt/homebrew/share/qemu/edk2-aarch64-code.fd`
  on macOS, `/usr/share/qemu/edk2-aarch64-code.fd` on Linux).
- Docker with an aarch64 Alpine container.
- The existing Alloy QEMU baseline for the kernel and systemd-boot:
  `devices/kukui-krane/baselines/1000/alloy-1001-floor.qcow2`.
  Alternatively set `DURANIUM_KERNEL` and `DURANIUM_EFI_BOOT`.

Build the fixture:

```sh
cd pkgs/duranium
./qemu/build-fixture.sh
```

Run all QEMU scenarios:

```sh
./tests/qemu/run-suite.sh
```

The suite copies a fresh fixture disk per scenario and boots until the guest
prints `DURANIUM_TEST:DONE`. Logs land in `qemu/out/runs/<timestamp>/`.

## Unit tests

```sh
./tests/run-unit.sh
```

On macOS this runs inside the aarch64 Alpine container, matching BusyBox and
OpenSSL behavior in the guest.

## Common commands inside a running Alloy/Duranium system

```sh
duranium status
duranium slot show A
duranium update verify /path/to/artifact
duranium update install /path/to/artifact
duranium mark-good
duranium mark-bad
duranium health report
duranium state schema
```

Recovery is entered by the `Alloy Recovery` systemd-boot entry or automatically
when no normal slot is usable:

```sh
duranium recovery status
duranium recovery inspect
duranium recovery repair-boot
duranium recovery reinstall --slot A --artifact /path/to/artifact
duranium recovery mount-state
duranium recovery factory-reset --mode os --yes
duranium recovery factory-reset --mode state --yes
```

## Update artifact format

```
artifact/
  manifest.txt
  manifest.sig
  system.img
  boot/vmlinuz
  boot/initramfs
```

The manifest is canonical key=value, signed with Ed25519 over the exact bytes
of `manifest.txt`. The payload and both boot artifacts are SHA-256 checked.
See `docs/04-UPDATE-MANIFEST.md`.

## What V1 does not do

No Chromium, SystemUI, Waydroid, ASHT, GUI recovery, network downloads, or
live `apk upgrade` updates. APK is a build input, not a production update
mechanism. See `docs/09-APK-POLICY.md` and `docs/12-LIMITATIONS.md`.

## Test status

The final local run recorded:

- Unit suite: **9/9 test scripts passed**.
- QEMU suite: **6/6 scenarios passed** across real UEFI/systemd-boot boots.
- 176 named guest assertions passed across 23 real boots with zero failures.

Exact logs and environment are recorded in `docs/11-TEST-RESULTS.md`.
