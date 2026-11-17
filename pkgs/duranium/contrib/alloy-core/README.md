# Alloy Core adapter (reference)

This directory contains the pieces needed to apply Duranium's model to the
real Alloy Core image. The green V1 acceptance suite uses the deterministic
QEMU fixture, not this adapter. Treat the adapter as the next integration
step, not as a tested production installer.

## What the real Core image needs

1. **Two system images.** Copy the Core root filesystem into SYSTEM_A and
   SYSTEM_B. Both are mounted read-only at runtime.
2. **Per-slot kernel + initramfs.** Each slot artifact includes its own
   `vmlinuz` and `initramfs`, under:
   ```
   /boot/duranium/boot/A/
   /boot/duranium/boot/B/
   ```
3. **A writable runtime view.** Alloy Core systemd expects a writable `/etc`
   and `/var`. Mount the slot read-only as the overlay lower layer, use tmpfs
   for the overlay upper/work layers, then bind the explicit STATE paths over
   the overlay.
4. **STATE binds.** At minimum:
   ```
   /state/home            → /home
   /state/var/lib/alloy   → /var/lib/alloy
   /state/etc/alloy       → /etc/alloy
   ```
   Add NetworkManager connections, SSH host keys, and Bluetooth pairings only
   with an explicit state-schema migration.
5. **BOOT at /boot.** Bind the FAT ESP at `/boot` so `duranium mark-good` and
   the updater can write BOOT metadata and entries.
6. **Duranium units.** Install and enable:
   ```
   duranium-boot-reconcile.service
   duranium-state-migrate.service
   ```
   Install `duranium-mark-good.service` but leave it disabled unless the
   product explicitly opts into automatic confirmation. V1's policy is manual
   `duranium mark-good`.
7. **Health checks.** Copy `duranium-health-core.sh` to
   `/etc/duranium/health.d/20-core-systemd.sh` and adjust the expected service
   list.

## Reference initramfs overlay

The real Core initramfs must include BusyBox, Duranium, and the overlay
module. A minimal shape is:

```sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t vfat -o rw /dev/vda1 /boot
mount -t ext4 -o ro /dev/vda3 /lower
mount -t tmpfs tmpfs /overlay
mkdir -p /overlay/upper /overlay/work
mount -t overlay overlay \
  -o lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work /sysroot
mount -t ext4 -o rw /dev/vda5 /sysroot/state

mkdir -p /sysroot/home /sysroot/var/lib/alloy /sysroot/etc/alloy
mount --bind /sysroot/state/home /sysroot/home
mount --bind /sysroot/state/var/lib/alloy /sysroot/var/lib/alloy
mount --bind /sysroot/state/etc/alloy /sysroot/etc/alloy

mount --bind /boot /sysroot/boot
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
exec switch_root /sysroot /sbin/init
```

The production adapter must also:
- verify the chosen slot's boot hashes;
- honor systemd-boot attempt filenames;
- write `/run/duranium/boot.env` (or let the root units call
  `duranium boot-record`);
- reboot on a pending-slot verification/mount failure so the next attempt is
  consumed;
- boot RECOVERY when a GOOD slot fails.

## Build pipeline

Packages remain a build input:

```
apk-built rootfs
  → system image ext4/EROFS
  → per-slot kernel/initramfs
  → signed Duranium manifest
  → inactive slot
```

Do not add `apk upgrade` to the production update path.

## Status

The overlay/state adapter is documented and the units are provided, but the
real Core systemd boot smoke test is a V1.1 task. The deterministic fixture
covers the metadata, transaction, boot-counting, rollback, STATE migration, and
recovery semantics against the real kernel, UEFI, systemd-boot, GPT, ext4, and
read-only/bind mounts.
