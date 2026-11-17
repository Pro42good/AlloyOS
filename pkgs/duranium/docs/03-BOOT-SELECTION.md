# Boot selection

## Backend: systemd-boot

V1 uses systemd-boot's native boot counting. Per-slot kernel and initramfs
files live on BOOT:

```
/boot/duranium/boot/A/vmlinuz
/boot/duranium/boot/A/initramfs
/boot/duranium/boot/B/vmlinuz
/boot/duranium/boot/B/initramfs
/boot/duranium/boot/recovery/vmlinuz
/boot/duranium/boot/recovery/initramfs
```

Entry names encode priority and remaining attempts:

```
duranium-b+3.conf    pending B, three attempts
duranium-a.conf      GOOD A, unlimited
duranium-recovery.conf
```

On each boot systemd-boot rewrites the suffix:

```
+3  →  +2-1  →  +1-2  →  +0-3  → skipped
```

The entry filename is the bootloader's authoritative attempt counter. The slot
initramfs copies it into metadata (`boot_attempts_remaining`) and records the
kernel boot ID for `mark-good`.

`loader.conf` sets a short timeout and no fixed default. Sort keys determine
order:

| Entry | Sort key |
|---|---|
| pending slot | `10-duranium-<slot>` |
| active GOOD slot | `20-duranium-<slot>` |
| inactive GOOD slot | `30-duranium-<slot>` |
| recovery | `90-duranium-recovery` |

Therefore pending beats active, active beats inactive, and recovery is last.

## Selection rules

1. If a pending slot has attempts left, systemd-boot selects it.
2. Otherwise the active GOOD slot is selected.
3. Otherwise another GOOD slot is selected.
4. If no normal entry is bootable, recovery is selected.
5. BAD and UNKNOWN slots have no automatic entry.

## Per-slot initramfs checks

After the kernel and initramfs load, the initramfs:

1. mounts BOOT read-write;
2. confirms its embedded slot marker matches `duranium.slot=` on the command
   line;
3. calls `duranium boot-record`;
4. synchronizes attempts from the entry filename;
5. verifies the kernel and initramfs hashes in slot metadata;
6. mounts the slot root read-only;
7. mounts and binds STATE;
8. binds BOOT at `/boot` and switch_roots.

If the booted slot is PENDING, it remains PENDING. Booting it is not
confirmation.

## Failure behavior

### Pending slot cannot mount or verify

The initramfs records the failure, syncs the attempt counter, and reboots. The
next boot consumes another systemd-boot attempt. After the third failure the
entry is exhausted, the slot is marked BAD, and the next boot selects the GOOD
slot.

### Pending slot's kernel cannot load

systemd-boot itself consumes the attempt before loading the kernel. After the
configured attempts, it skips the entry and boots the next one. This was
exercised with a deliberately destroyed B kernel: A booted after three B
attempts.

### Active GOOD slot fails

The initramfs marks it BAD, chooses the fallback if it is GOOD, synchronizes
entries, and boots recovery if no normal slot remains.

### BAD slot

No automatic entry is written. `slot_reconcile` removes stale entries.

## Reconciliation

`duranium boot-reconcile` is idempotent and runs at boot. It:

- treats an interrupted `update_in_progress` target as BAD;
- reads pending entry suffixes;
- marks pending slots BAD when attempts reach zero or the entry disappears;
- completes a partially committed mark-good;
- repairs active/fallback pointers to point only at GOOD slots;
- rewrites entries when needed.

## Test coverage

- GOOD A boots normally.
- PENDING B takes priority over A.
- Booting B without mark-good leaves it PENDING and decrements attempts.
- Three failed B attempts mark it BAD and return to A.
- BAD is not retried.
- A still boots when B is completely unbootable.
- A corrupt pending kernel falls back after boot counting.
- A corrupt pending root falls back after three attempts.

## Explicit mark-good

A pending slot does not become GOOD because PID 1 started. `duranium mark-good`
requires all of the following:

1. the named slot is the currently booted slot;
2. `global.pending_slot` names that slot;
3. the slot status is `PENDING`;
4. the slot's `pending_boot_id` matches the current kernel boot ID;
5. health checks pass.

Health checks cover:

- `/` is mounted read-only;
- STATE is mounted;
- the Core readiness signal exists (`/run/alloy/core-ready`) or systemd is
  healthy with no failed units;
- expected services are active (or their fixture markers exist);
- `/etc/duranium/health.d/*.sh` extensions pass.

On success, the slot becomes GOOD, attempts are cleared, the entry loses its
`+N` suffix, and global active/fallback are updated. A failed check leaves the
slot PENDING and logs the refusal.
