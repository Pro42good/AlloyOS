# Persistent STATE model

## Principle

Do not persist all of `/etc` or `/var`. Only explicitly declared paths survive.
Image-owned defaults remain in the immutable system slot.

V1 uses this minimal persistent allowlist:

```
persistent:  /home
             /var/lib/alloy
             /etc/alloy
recreatable: /var/cache
             /var/log
ephemeral:   /run
             /tmp
             /var/tmp
```

The declaration is `/etc/duranium/state.conf`:

```
schema=1
path=/home persistent
path=/var/lib/alloy persistent
path=/etc/alloy persistent
path=/var/cache recreatable
path=/var/log recreatable
path=/run ephemeral
path=/tmp ephemeral
path=/var/tmp ephemeral
```

## Classes

| Class | Backing | Survives reboot | Survives update/rollback | Notes |
|---|---|---|---|---|
| persistent | STATE | yes | yes | user/application/OS configuration |
| recreatable | STATE | yes | yes | safe to delete/recreate |
| ephemeral | tmpfs | no | no | never written to STATE |

## Mount layout

The initramfs mounts STATE at `/state` in the new root, then:

```
/state/home              bind -> /home
/state/var/lib/alloy     bind -> /var/lib/alloy
/state/etc/alloy         bind -> /etc/alloy
/state/var/cache         bind -> /var/cache
/state/var/log           bind -> /var/log
tmpfs                    mount -> /run, /tmp, /var/tmp
```

The image must contain the mountpoint directories. Because `/etc/alloy` is
overlaid by STATE, image-owned markers must live elsewhere. The fixture uses
`/etc/alloy-version` for this reason.

## STATE-owned metadata

```
/state/duranium/schema
/state/duranium/bootlog
/state/duranium/boot/<slot>.state
/state/duranium/backups/
/state/duranium/updates.log
/state/duranium/duranium.log
```

Update history and diagnostics are in STATE, but **boot-critical** slot and
global metadata are on BOOT. A missing or corrupt STATE cannot change which
slot is selected. A non-numeric `/state/duranium/schema` is treated as
corrupt: installs and migrations fail closed rather than silently skipping
the schema checks.

`/state/duranium/bootlog` is an append-only evidence journal (boot
confirmations, sign-ins, crash reports, clean shutdowns, detections).
`/state/duranium/boot/<slot>.state` holds the most recent userland boot of
each slot so the next boot can detect an unclean shutdown. Both are
diagnostics and `mark-good` gating evidence only: they never influence
which slot is selected.

## Ephemeral and recreatable behavior

- `/run`, `/tmp`, and `/var/tmp` are fresh tmpfs mounts every boot. Files
  written there are intentionally gone after reboot.
- `/var/cache` and `/var/log` live in STATE but are classified as recreatable:
  they may be deleted by repair/reset logic without losing user data.
- A factory OS reset preserves STATE; a separate explicit STATE reset wipes it.

## Extending the allowlist

Add a path only when the application has an explicit migration story. For a
real Alloy Core image, likely additions are:

```
path=/etc/NetworkManager/system-connections persistent
path=/etc/ssh persistent
path=/var/lib/bluetooth persistent
```

Each addition must be reflected in a STATE schema migration if existing
systems need the data moved or duplicated. Do not persist the entire `/etc`.

## Factory reset semantics

`duranium recovery factory-reset --mode os`:

- invalidates SYSTEM_A and SYSTEM_B and their boot artifacts;
- sets active/pending/fallback to empty;
- keeps STATE intact.

`--mode state`:

- wipes and recreates the STATE filesystem;
- leaves the OS slots untouched.

`--mode full`:

- does both.

All three require an explicit `--yes`.
