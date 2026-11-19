# QEMU V1 integration

## Why a dedicated fixture

QEMU is the first implementation target, but Duranium's metadata, transaction,
STATE, and recovery logic is behind backends and does not depend on QEMU.

The fixture is deliberately small and deterministic:

- real aarch64 kernel;
- real EDK2 UEFI;
- real systemd-boot with boot counting;
- real GPT, FAT32, ext4, read-only mounts, bind mounts, and tmpfs;
- minimal Alpine userland with BusyBox and OpenSSL;
- signed per-slot artifacts on a separate read-only test-data disk.

It is not a graphical Alloy desktop. It uses the same boot and storage
mechanics as Alloy Core and is designed to be replaced by a real Core adapter
for a systemd smoke test.

## Prerequisites

- `qemu-system-aarch64` with `virt`, EDK2 firmware.
- Docker with an aarch64 Alpine image for filesystem construction.
- A kernel and aarch64 systemd-boot EFI binary. The builder extracts both from
  `devices/kukui-krane/baselines/1000/alloy-1001-floor.qcow2` by default.
  Override with `DURANIUM_BASELINE` (directory) or
  `DURANIUM_KERNEL` + `DURANIUM_EFI_BOOT`.

The host does not need ext4 or mtools installed. All image tools run in the
container.

## Build

```sh
cd pkgs/duranium
./qemu/build-fixture.sh
```

Outputs (ignored by git):

```
qemu/out/duranium-fixture.img   660 MiB raw GPT disk
qemu/out/testdata.img            1.5 GiB ext4 artifact/scenario disk
qemu/out/fixture.env             partition offsets
qemu/out/keys/                   ephemeral test signing keys
```

The build:

1. extracts `vmlinuz` and `BOOTAA64.EFI` from the baseline ESP;
2. builds one Alpine base root filesystem;
3. creates per-slot rootfs images and per-slot initramfs;
4. writes initial metadata and systemd-boot entries;
5. assembles BOOT/RECOVERY/A/B/STATE partitions;
6. creates signed B-v2 and A-v3 artifacts plus rejection variants;
7. creates the test-data disk with scenario scripts.

## Disk map

| Partition | Start | Size | Contents |
|---|---|---|---|
| BOOT | 1 MiB | 128 MiB | FAT32, systemd-boot, kernels/initramfs, metadata |
| RECOVERY | 129 MiB | 128 MiB | ext4 recovery userland |
| SYSTEM_A | 257 MiB | 128 MiB | initial A-v1 image |
| SYSTEM_B | 385 MiB | 128 MiB | empty initially |
| STATE | 513 MiB | 128 MiB | seeded settings/user files |

The host runner uses these offsets to simulate catastrophic corruption with
`dd` while QEMU is off.

## Run one boot

```sh
./qemu/run-vm.sh \
  --disk qemu/out/duranium-fixture.img \
  --testdata qemu/out/testdata.img \
  --log /tmp/duranium-boot.log \
  --timeout 75
```

The runner uses:

- HVF on macOS, KVM on Linux when available, TCG fallback;
- fresh writable NVRAM per invocation (important: stale NVRAM from another
  image produced EDK2 boot-entry errors during development);
- `-no-reboot`, so guest poweroff/reboot ends QEMU;
- serial output to the log file.

## Test suite

```sh
./tests/qemu/run-suite.sh
```

Each scenario gets a fresh copy of the fixture disk. The guest agent reads the
scenario name and phase from STATE, performs one step, logs assertions to the
serial console, and powers off. The host boots again until `DURANIUM_TEST:DONE`
or `DURANIUM_TEST:FAIL`.

Scenarios:

| Scenario | Purpose |
|---|---|
| `acceptance` | clean A, install B, boot PENDING B twice, mark good, update A, state survival, corrupt B root, three-attempt rollback |
| `failures` | tampered payload/manifest, untrusted key, wrong profile/arch/hardware, injected write/read-back failures, power loss |
| `recovery-both` | A and B destroyed before boot; recovery reinstall + STATE preservation |
| `recovery-a` | A destroyed, B not bootable; recovery reinstall |
| `recovery-mixed` | B broken but A boots; A then destroyed; recovery reinstall |
| `corrupt-boot` | B kernel destroyed after a valid update; systemd-boot counting falls back to A |

Run a subset:

```sh
DURANIUM_QEMU_SCENARIOS="recovery-mixed corrupt-boot" ./tests/qemu/run-suite.sh
```

Logs and per-boot NVRAM are under
`qemu/out/runs/<timestamp>/<scenario>/`.

## Scenario authoring

Scenario scripts live in `tests/qemu/scenarios/` and are copied into the
test-data disk. A step calls one of:

- `advance` — increment phase, power off, let the host boot again;
- `finish` — log DONE and power off;
- `fail` — log FAIL and power off;
- `request_corrupt A|B` — increment phase, log a host request, power off.

Helpers include `expect_eq`, `expect_slot_status`, `expect_active`,
`expect_pending`, `expect_contains`, `run_or_fail`, `expect_fail`, and STATE
seed checks.

## Test-data updates between runs

The host uses `debugfs` inside an Alpine container to replace `/scenario` on
the ext4 test-data image. The guest mounts the test-data disk read-only.

## Kernel and bootloader gotchas

- The checked-in `vars.fd` files from earlier lab images contained stale boot
  entries. The runner creates fresh 64 MiB NVRAM per boot.
- The build extracts the systemd-boot EFI binary from the existing Alloy ESP.
  A future V1.1 should package a pinned systemd-boot binary.
- The fixture kernel has `virtio_blk`, `virtio_pci`, `ext4`, `vfat`, and
  `tmpfs` built in; no initramfs modules are required.
- The QEMU disk is raw, not qcow2, so host-side corruption and boot-counting
  entry rewrites are easy to inspect.

## Real Alloy Core adapter

See `contrib/alloy-core/`. The semantic fixture is the acceptance target for
V1. A real-Core systemd smoke test remains an optional follow-up; the adapter
documents the required overlay-root and STATE bind setup.
