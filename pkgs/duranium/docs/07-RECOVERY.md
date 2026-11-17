# Recovery environment

## Independence

Recovery must work when SYSTEM_A, SYSTEM_B, or both are broken. It uses:

- a recovery kernel and initramfs on BOOT (UEFI/systemd-boot can only read the
  FAT ESP);
- an independent ext4 userland on the RECOVERY partition;
- direct access to BOOT metadata and the system/state partitions.

It does not mount or execute either normal system slot to run recovery.

The systemd-boot entry `Alloy Recovery` is always present with sort key 90. It
is selected automatically when no normal slot has a bootable entry. The slot
initramfs also redirects to recovery when a GOOD slot fails to mount.

## Userland

The RECOVERY partition contains BusyBox, OpenSSL, the Duranium CLI and its
libraries, and the recovery init. It is CLI-only in V1:

```
DURANIUM_RECOVERY_READY
Duranium recovery shell. Try: duranium recovery status
```

## Commands

| Command | Purpose |
|---|---|
| `duranium recovery status` | metadata, entries, STATE mount |
| `duranium recovery inspect` | slot/device hashes, boot artifacts, entry state |
| `duranium recovery select A\|B [--force]` | change active/fallback slot |
| `duranium recovery mark-good A\|B` | explicit repair transition |
| `duranium recovery mark-bad A\|B` | mark a slot unusable |
| `duranium recovery reinstall --slot A\|B --artifact DIR` | verified reinstall |
| `duranium recovery repair-boot` | restore metadata backups, rebuild entries |
| `duranium recovery mount-state` / `umount-state` | explicit STATE access |
| `duranium recovery factory-reset --mode os\|state\|full --yes` | explicit reset |

`recovery reinstall` uses the same signed-manifest and read-back verification
as a normal update. It preserves STATE by default; only `factory-reset` modes
`state` or `full` wipe it.

## Boot path

```
systemd-boot
  └─ recovery kernel + initramfs (BOOT)
       ├─ mount BOOT rw
       ├─ mount RECOVERY at /recovery
       ├─ bind BOOT at /recovery/boot
       ├─ switch_root /recovery /sbin/init
       └─ recovery PID 1
            ├─ mount /dev/vdb read-only when present (test data)
            ├─ mount STATE when requested
            ├─ print status
            └─ run test agent or interactive shell
```

## Repair behavior

`repair-boot`:

- restores a primary metadata file from `.bak` when the primary is invalid;
- creates conservative `UNKNOWN` records when neither copy is valid;
- reconstructs a missing global record from GOOD slot metadata;
- clears a pending pointer that is not actually PENDING;
- chooses a GOOD active/fallback pair when possible;
- rewrites loader entries from metadata.

It never invents a GOOD status for a slot whose metadata is missing.

## Explicit reset semantics

- OS reset: invalidate the OS slots and their boot artifacts; keep STATE.
- STATE reset: wipe and recreate STATE; keep the OS slots.
- Full reset: both; requires `--yes`.

## Test coverage

The QEMU suite exercises:

- recovery boots with both A and B corrupt (`recovery-both`);
- recovery boots with A corrupt and B not bootable (`recovery-a`);
- B is broken, A boots normally, then A is corrupted and recovery boots
  (`recovery-mixed`);
- recovery reinstall of A from a signed artifact;
- STATE survives recovery reinstall, boot, schema migration, and mark-good;
- recovery selection/repair commands;
- explicit OS reset preserving STATE;
- explicit STATE reset refusing to run without `--yes`.
