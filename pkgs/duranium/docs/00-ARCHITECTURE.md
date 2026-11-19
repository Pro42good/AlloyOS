# Duranium V1 architecture

## Goal

Prove that a working immutable Alloy system can be updated without ever
sacrificing the currently bootable system. V1 is intentionally small, local,
and testable. It is not a finished user-facing updater.

## Invariants

1. The running slot's filesystem is mounted read-only and is never written by
   an update.
2. Every update is written to the inactive slot only.
3. The inactive slot is made explicitly non-bootable (`UNKNOWN`) before the
   first destructive write.
4. A new slot becomes `PENDING` only after signature, payload, boot-artifact,
   and read-back hash verification.
5. A pending slot is selected ahead of the confirmed slot until its attempts
   run out.
6. A pending slot becomes `GOOD` only through an explicit `mark-good` that
   passes health checks.
7. A failed or unconfirmed pending slot is marked `BAD` and is never retried
   automatically.
8. Boot-critical metadata lives on BOOT, not STATE.
9. STATE is a separate partition and survives updates, rollbacks, and
   reinstallation.
10. Only explicitly declared STATE paths persist.
11. A pending update must not make an irreversible STATE change while a
    rollback slot is expected.
12. Recovery does not depend on either normal system slot.

## Components

| Component | Location | Responsibility |
|---|---|---|
| CLI | `src/bin/duranium` | One entry point for normal, initramfs, recovery, tests |
| Metadata | `src/lib/metadata.sh` | Strict slot/global records, checksums, dual copies |
| Bootloader backend | `src/lib/bootloader.sh` | systemd-boot entries and boot counting |
| Slot control | `src/lib/slot.sh` | Boot recording, reconciliation, mark-good/bad, selection |
| Manifest | `src/lib/manifest.sh` | Canonical manifest, SHA-256, Ed25519 trust |
| Updater | `src/lib/update.sh` | Inactive-slot write, verification, transaction |
| STATE | `src/lib/state.sh` | Allowlist, mounts, ephemeral paths, migrations |
| Health | `src/lib/health.sh` | Root/STATE/core/service gates for mark-good |
| Recovery | `src/lib/recovery.sh` | Inspect, repair, select, reinstall, reset |
| Initramfs | `src/lib/initramfs.sh` | Per-slot mount and switch_root |
| Backends | `src/lib/backend.sh` | Block devices or test directories |

## Boot flow

```
UEFI firmware
  └─ systemd-boot on BOOT (FAT)
       ├─ duranium-b+3.conf  → BOOT/duranium/boot/B/vmlinuz + initramfs
       ├─ duranium-a.conf    → BOOT/duranium/boot/A/vmlinuz + initramfs
       └─ duranium-recovery.conf → recovery userland
              │
              ▼
       per-slot initramfs
         ├─ mount BOOT rw
         ├─ verify slot metadata and boot artifact hashes
         ├─ synchronize the attempt counter from the entry filename
         ├─ mount SYSTEM_x read-only
         ├─ mount STATE, bind declared persistent paths
         ├─ mount tmpfs for /run, /tmp, /var/tmp
         ├─ bind BOOT at /boot
         └─ switch_root
```

systemd-boot's native boot counting provides the fallback if a slot kernel
cannot be loaded at all. The per-slot initramfs handles the case where the
kernel loads but the root or boot artifacts are invalid.

## Update flow

```
verify manifest signature
verify payload + boot hashes
check profile / architecture / hardware / STATE schema
determine inactive slot
mark target UNKNOWN + record update_in_progress on BOOT
remove the target's old boot entry
write root image to target partition
read back exactly the image length and hash it
check the filesystem
write target kernel + initramfs into BOOT
verify those hashes
mark target PENDING
write target entry "duranium-<slot>+3.conf"
clear update_in_progress
```

Any failure before `PENDING` leaves the active/fallback selection unchanged.
A crash leaves `update_in_progress` set; the next boot marks the target `BAD`.

## STATE flow

```
SYSTEM_x (ro) ──┐
                ├─ switch_root root
STATE (rw) ─────┼─ /home
                ├─ /var/lib/alloy
                ├─ /etc/alloy
                ├─ /var/cache, /var/log (recreatable)
                └─ /state/duranium (schema, backups, history)

tmpfs ─────────── /run, /tmp, /var/tmp
```

Image-owned defaults remain in the immutable image. The bind over
`/etc/alloy` means image defaults under that directory are intentionally
overridden by STATE; the image version marker therefore lives at
`/etc/alloy-version`, outside the bind.

## Recovery flow

```
systemd-boot
  └─ recovery kernel + initramfs (BOOT)
       └─ mount RECOVERY userland at /recovery
            ├─ bind BOOT at /boot
            ├─ mount STATE at /state when requested
            └─ CLI: status / inspect / repair / select / mark / reinstall /
                    mount-state / factory-reset
```

RECOVERY is an ext4 userland. The recovery kernel/initramfs necessarily live
on BOOT because the UEFI firmware and systemd-boot read the FAT ESP. RECOVERY
does not need SYSTEM_A or SYSTEM_B.

## Backend abstraction

Core logic addresses logical areas (`A`, `B`, `STATE`, `RECOVERY`, `BOOT`).
`backend.sh` maps them to:

- `block`: real GPT partitions by label or configured device.
- `dir`: files/directories for unit tests.

`bootloader.sh` maps slot state to systemd-boot entries. The metadata, STATE,
manifest, and update logic does not know whether the bootloader is
systemd-boot, a future EFI boot manager, U-Boot, or Depthcharge. A different
platform implements the same bootloader interface.

## Trust model and assumptions

- BOOT is trusted boot-critical storage. V1 does not implement Secure Boot or
  signed boot metadata.
- Update artifacts are verified with pinned Ed25519 public keys.
- root on the running system can alter BOOT and device state; V1 is not a
  privilege-escalation boundary.
- STATE is not encrypted in V1.
- The systemd-boot binary itself is a single point of failure and is not A/B
  duplicated in V1.

## Out of scope for V1

Network updates, GUI tools, user-facing recovery, APK-on-live-system updates,
encryption, delta updates, per-slot bootloader redundancy, and rich Alloy
service health checks.
