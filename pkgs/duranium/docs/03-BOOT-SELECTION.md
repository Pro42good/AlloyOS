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
entries, and reboots so systemd-boot selects the fallback entry. Recovery is
booted only if no normal slot remains.

### BAD slot

No automatic entry is written. `slot_reconcile` removes stale entries.

## Reconciliation

`duranium boot-reconcile` is idempotent and runs at boot. It:

- treats an interrupted `update_in_progress` target as BAD;
- reads pending entry suffixes;
- marks pending slots BAD when attempts reach zero or the entry disappears;
- completes a partially committed mark-good;
- rewrites a GOOD slot's entry when it is missing or still carries a boot
  counter (the mark-good crash window between the metadata commit and the
  entry sync);
- clears a pending pointer that does not name a PENDING slot (e.g. restored
  from an older metadata backup);
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
5. the booted OS confirmed this boot with `duranium boot-confirm` (the
   `confirmed=1` flag in `/run/duranium/boot.env`);
6. when `DURANIUM_REQUIRE_SESSION=1`, the sign-in gate confirmed the user
   session (`duranium session-confirm`, the `session=1` flag);
7. this boot has no reported session crash (`duranium session-crash`);
8. health checks pass.

There is deliberately no root-image hash in this list: mark-good runs on
the mounted root, and a mounted ext4's raw bytes are not a function of the
installed image (the kernel keeps journal/superblock buffers in the
block-device page cache; read-only mounts never write them back). Byte
integrity is verified where it is sound: install-time readback on the
unmounted target, and the mandatory pre-mount root hash in the initramfs
(see "Boot sequence invariants" below).

Health checks cover:

- `/` is mounted read-only; for an overlay root, the lower SYSTEM layer
  must be read-only;
- STATE is mounted;
- the Core readiness signal exists (`/run/alloy/core-ready`) or systemd
  reports `running` with no failed units ("starting" is refused: units may
  still be about to fail);
- expected services are active (or their fixture markers exist);
- `/etc/duranium/health.d/*.sh` extensions pass.

On success, the slot becomes GOOD, attempts are cleared, the entry loses its
`+N` suffix, and global active/fallback are updated. A failed check leaves the
slot PENDING and logs the refusal.

## Boot and session confirmation

Booting a slot and proving the boot usable are different events:

- systemd-boot counting covers failures **before** userland: a kernel or
  initramfs that never runs consumes the entry's attempts and the slot
  eventually falls back.
- A kernel that loads, launches processes, and then freezes partway through
  userland would otherwise look identical to a completed boot to anything
  that only reads metadata.
- Even reaching userland is not proof on a desktop: the environment can
  crash shortly after the user signs in.

The booted OS therefore confirms its own boot through a two-stage, per-boot
handshake. Both stages write flags into `/run/duranium/boot.env` (tmpfs, so
they are per-boot by construction; the next `boot-record` rewrites the file)
and append to the evidence journal in STATE (`/state/duranium/bootlog`).

```
duranium boot-confirm      # stage 1: the OS finished booting
duranium session-confirm   # stage 2: the user signed in and the
                           #          environment is up (sign-in gate)
```

- `boot-confirm` requires a boot record for the current boot and matches the
  record's slot against the booted slot. `mark-good` always requires it.
- `session-confirm` requires `boot-confirm` first (ordering is enforced).
  V1 ships the gate as a **stub that is not called by anything in the
  fixture** (there is no user session); it is enforced only when
  `DURANIUM_REQUIRE_SESSION=1`, which the real Alloy desktop sets. The
  intended caller is the sign-in flow itself: once the user logs in, the
  system confirms via the API (and may then chain the explicit
  `duranium mark-good`).
- In the fixture, PID 1 confirms at its "OS is up" point because PID 1 *is*
  the fixture's whole userland. In a real Core image the confirm must be a
  late systemd unit (`contrib/alloy-core/duranium-boot-confirm.service`),
  never the initramfs or early PID 1.

## Crash detection

Duranium records boot evidence so crashes after userland are visible and
actionable:

- **Explicit crash report.** The booted OS calls
  `duranium session-crash [reason]` when the environment crashes (e.g.
  shortly after sign-in). The report is journaled, the per-boot `crash`
  flag is set (refusing `mark-good` for that boot), and the crash is acted
  on by slot status:
  - **PENDING slot:** marked BAD immediately, pending pointer cleared, and
    the next boot falls back. The OS itself judged the candidate unusable;
    failed candidates are not retried automatically.
  - **GOOD slot:** recorded, never demoted. GOOD status changes only through
    explicit operator action in V1; repeated-crash policy is a future
    decision, not an automatic one.
- **Unclean-shutdown detection.** Each confirmed/sign-in boot writes a
  durable per-slot record under `/state/duranium/boot/<slot>.state`. On the
  next `boot-confirm`, if the previous boot of that slot reached userland
  but has no clean-shutdown record, Duranium logs a warning and journals
  `DETECTED`.
- **Clean shutdown.** The OS calls `duranium boot-clean` at shutdown; the
  fixture's test agent calls it before every power-off. A CLEAN record
  suppresses the detection on the next boot.

The journal and records are diagnostics and gating evidence, not
boot-critical metadata: corrupt or missing boot evidence can never change
which slot is selected.
