# Slot and global metadata

## Storage

Authoritative metadata is on BOOT, not STATE:

```
/boot/duranium/global.meta      + global.meta.bak
/boot/duranium/slots/A.meta     + A.meta.bak
/boot/duranium/slots/B.meta     + B.meta.bak
```

Each file is a canonical sequence of `key=value` lines followed by exactly one
`checksum=<sha256>` line. The checksum covers every byte before the checksum
line, including its trailing newline.

## Slot fields (fixed order)

```
duranium_meta=1
kind=slot
slot=A
alloy_version=1.0
build_id=A-v1
image_sha256=<64 hex>
image_size=<bytes>
boot_kernel_sha256=<64 hex>
boot_initramfs_sha256=<64 hex>
profile=prod
architecture=aarch64
hardware_target=qemu-aarch64-virt
state_schema=1
status=GOOD
boot_attempts_remaining=0
max_boot_attempts=3
known_good=1
pending_boot_id=
generation=1
updated_at=2026-11-17T00:00:00Z
checksum=<64 hex>
```

## Global fields (fixed order)

```
duranium_meta=1
kind=global
active_slot=A
pending_slot=
fallback_slot=A
last_known_good_slot=A
update_in_progress=
generation=1
updated_at=2026-11-17T00:00:00Z
checksum=<64 hex>
```

`active_slot` is the last confirmed GOOD slot. While a pending slot is booted,
`active_slot` deliberately remains the previous GOOD slot; the booted slot is
reported separately as `booted slot`.

`image_size` records the exact byte length of the installed system image.
`image_sha256` covers exactly those bytes, **not** the whole slot partition:
partitions are provisioned with headroom, and the partition tail contains
whatever preceded the install. The hash is verified at exactly two points:
install read-back and the initramfs boot check, both **before the slot is
mounted** (a mounted ext4's raw bytes legitimately diverge from the image:
journal and superblock buffers live in the block-device page cache and
read-only mounts never write them back). It is never verified from the
booted OS. Metadata written before `image_size` existed is verified against
the full device size, which only matches when the image fills the partition.

## States

| Status | Meaning | Automatically booted? |
|---|---|---|
| `UNKNOWN` | no trusted image, or an interrupted update | No |
| `PENDING` | installed and verified, not yet confirmed | Yes, while attempts remain |
| `GOOD` | explicitly confirmed healthy | Yes |
| `BAD` | known broken/exhausted | No |

## Deterministic transitions

```
install:         UNKNOWN -> PENDING   (attempts = max, known_good = 0)
pending boot:    PENDING -> PENDING   (attempts decremented by bootloader)
mark-good:       PENDING -> GOOD      (known_good = 1, attempts = 0)
attempts == 0:   PENDING -> BAD       (pending cleared)
mark-bad:        any     -> BAD       (known_good = 0, attempts = 0)
update start:    inactive -> UNKNOWN  (before destructive write)
update failure:  target   -> BAD      (active selection unchanged)
```

A GOOD slot can be selected as active/fallback. A BAD slot is never selected
automatically.

## Validation rules

The parser rejects:

- missing mandatory fields;
- unknown fields (the schema is closed; field-order changes are rejected);
- duplicate fields;
- invalid checksums;
- a `checksum=` line that is not the final line;
- non-canonical field order;
- invalid `slot` values;
- statuses outside `UNKNOWN|PENDING|GOOD|BAD`;
- `profile` outside `dev|lab|prod`;
- non-numeric generation/schema/attempt fields;
- attempts greater than `max_boot_attempts`;
- GOOD/PENDING records with missing or malformed image/boot hashes;
- GOOD records with `known_good` not equal to 1;
- UNKNOWN/BAD records with non-zero attempts;
- unknown slot names in global pointers;
- `active_slot == pending_slot` when both are set.

Values are single tokens. Spaces, newlines, `=`, carriage returns, and
non-schema characters are rejected. This keeps parsing deterministic on FAT.

## Redundancy and corruption behavior

Writes use temp file → sync → rename → sync. Before replacing a valid primary,
the previous primary is copied to `.bak`. A corrupt primary is never allowed to
overwrite a valid backup.

Reads try the primary, then the backup. If both are invalid:

- slot metadata is treated as unusable for that slot only;
- the other slot's metadata is unaffected;
- the boot selector falls back to the other GOOD slot or recovery.

The parser is deliberately conservative: malformed mandatory fields do not
degrade into guessed values.

## Boot-critical independence from STATE

The attempt counter and slot/global metadata are on BOOT. STATE contains only
diagnostic history, backups, and user/application data. If STATE is missing or
corrupt, slot selection still works; `mark-good` health checks fail instead of
silently confirming the slot.

## Example: mark-good B

After a healthy pending B boot:

- `B.meta`: `status=GOOD`, `known_good=1`, `boot_attempts_remaining=0`
- `global.meta`: `active_slot=B`, `pending_slot=`, `fallback_slot=A`,
  `last_known_good_slot=B`
- `duranium-b.conf` has no `+N` suffix

Only the currently booted pending slot can perform this transition, and its
recorded `pending_boot_id` must match the current kernel boot ID.
