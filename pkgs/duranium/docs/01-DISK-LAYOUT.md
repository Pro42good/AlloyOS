# Disk and filesystem layout

## GPT layout

Duranium uses a GPT disk. The reference QEMU fixture uses 1 MiB alignment and
128 MiB areas; production sizes are configurable.

| # | GPT label | Type | FS | Size (fixture) | Mount | Purpose |
|---|---|---|---|---|---|---|
| 1 | `duranium-boot` | EFI System | FAT32 | 128 MiB | `/boot` | systemd-boot, per-slot kernels/initramfs, metadata |
| 2 | `duranium-recovery` | Linux | ext4 | 128 MiB | `/recovery` while booting | independent recovery userland |
| 3 | `duranium-system-a` | Linux | ext4 | 128 MiB | `/` (ro) | SYSTEM_A image |
| 4 | `duranium-system-b` | Linux | ext4 | 128 MiB | `/` (ro) | SYSTEM_B image |
| 5 | `duranium-state` | Linux | ext4 | 128 MiB | `/state` (rw) | persistent STATE |

The fixture disk is 660 MiB. Partition starts are 1, 129, 257, 385, and
513 MiB. The generated `qemu/out/fixture.env` records the offsets used by the
test harness.

## Why these filesystems

- **BOOT: FAT32** because UEFI firmware and systemd-boot read it directly.
- **SYSTEM_A/B: ext4** for V1. The updater treats a slot as an opaque image
  blob plus a kernel/initramfs pair, so EROFS, squashfs, or another
  read-only-oriented filesystem can replace ext4 without changing manifest,
  metadata, selection, or transaction logic. The backend would only need to
  mount the slot appropriately.
- **STATE: ext4 read-write** because it is the only general writable
  persistent filesystem.
- **RECOVERY: ext4** for a simple independent userland. The recovery kernel
  and initramfs are on BOOT because UEFI/systemd-boot cannot read ext4.

## Mount contract while a slot is running

- `/` is the selected SYSTEM slot, mounted read-only.
- `/boot` is the BOOT FAT, mounted read-write (metadata and updates).
- `/state` is the STATE partition, mounted read-write.
- Declared STATE paths are bind-mounted from `/state`.
- `/run`, `/tmp`, and `/var/tmp` are tmpfs.
- `/proc`, `/sys`, and `/dev` are kernel/virtual filesystems.

The running slot's block device is never opened for writing by a normal update.

## No swap partition

Duranium V1 intentionally has no swap partition. The expected memory hierarchy
is:

```
RAM → ZRAM → optional swapfile in STATE
```

A swapfile must live in STATE (or another explicitly configured persistent
area), never in a system slot. The updater does not create or manage swap.

## BOOT contents

```
/boot/
  EFI/BOOT/BOOTAA64.EFI          systemd-boot
  loader/loader.conf             timeout and selection policy
  loader/entries/
    duranium-a.conf              GOOD active/inactive A
    duranium-b+3.conf            PENDING B with three attempts
    duranium-recovery.conf       recovery
  duranium/
    global.meta (+ .bak)         authoritative global state
    slots/A.meta (+ .bak)        authoritative A metadata
    slots/B.meta (+ .bak)        authoritative B metadata
    boot/
      A/vmlinuz, A/initramfs
      B/vmlinuz, B/initramfs
      recovery/vmlinuz, recovery/initramfs
      <slot>/manifest.txt, manifest.sig   diagnostic copy only
```

`duranium/boot/*/manifest.*` is a convenience copy for inspection; activation
decisions use the verified local artifact, not the BOOT copy.

## STATE contents

```
/state/
  home/                    → /home
  var/lib/alloy/           → /var/lib/alloy
  etc/alloy/               → /etc/alloy
  var/cache/               → /var/cache      (recreatable)
  var/log/                 → /var/log        (recreatable)
  duranium/
    schema                 persistent state schema
    backups/               migration backups
    updates.log            update history
    duranium.log           slot transitions
```

## Fixture verification

The QEMU suite checks, with real mounts:

- both slots are separate GPT partitions;
- the active slot is mounted read-only;
- STATE is mounted separately;
- the inactive slot can be mounted read-only;
- recovery is independently addressable;
- rewriting SYSTEM_B does not change SYSTEM_A or STATE;
- rewriting SYSTEM_A does not change STATE;
- STATE survives slot replacement and recovery reinstall.
