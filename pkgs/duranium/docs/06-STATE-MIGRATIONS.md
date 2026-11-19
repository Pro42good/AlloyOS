# STATE schema and migration framework

## Schema marker

The current persistent state schema is stored at:

```
/state/duranium/schema
```

It is a single integer. Each slot image declares the schema it requires in its
slot metadata (`state_schema`), sourced from the update manifest's
`state_schema_required`.

## Migration files

A migration from schema N to N+1 is a pair in the image:

```
/usr/lib/duranium/migrations/N-to-N+1.conf
/usr/lib/duranium/migrations/N-to-N+1.sh
```

Example:

```
from=1
to=2
kind=backward-compatible
```

Allowed kinds:

| Kind | Allowed while rollback expected? | Rule |
|---|---|---|
| `backward-compatible` | yes | old slot can still operate on the new state |
| `reversible` | yes | a reverse path exists |
| `duplicated` | yes | old data is retained and new data is added |
| `irreversible` | no | rejected if a GOOD rollback slot is expected |

The V1 example `1-to-2.sh` copies `/state/etc/alloy/settings.conf` to
`/state/etc/alloy/v2/settings.conf` and leaves the old path intact. Slot A
(schema 1) still reads the old path after a rollback; slot B (schema 2) reads
the new namespace.

## When migrations run

On first boot of a pending slot:

1. boot-record and reconciliation complete;
2. the root init calls `duranium state migrate <slot>`;
3. the required schema is read from the slot metadata;
4. each missing step runs in order;
5. the schema marker advances only after a step succeeds.

If migration fails:

- the pending slot is marked BAD;
- the pending pointer is cleared;
- the system reboots to the GOOD fallback;
- the old STATE data remains readable by the old slot.

## Backup

Before each step the whole STATE tree (excluding `.duranium/backups`) is saved
as a tar under:

```
/state/duranium/backups/before-N-to-N+1-<epoch>.tar
```

The backup is best-effort recovery material in V1. Additive migrations should
not need destructive restore.

## Rollback rule

A pending update must not irreversibly modify persistent state in a way that
prevents returning to the last GOOD slot.

V1 therefore:

- accepts only backward-compatible, reversible, or duplicated migrations;
- rejects `irreversible` migrations while a GOOD fallback is expected;
- allows the older slot to boot with a newer schema because the accepted
  migrations are additive.

The update installer also rejects an artifact whose required schema exceeds
the current schema unless the manifest declares both
`state_schema_backward_compatible=1` and `rollback_compatible=1`.

## Test coverage

- schema N understanding: initial schema 1.
- schema N → N+1 safe migration: settings copied to v2, old path retained.
- rollback B → A with state schema 2: A still reads state.
- failed migration: B marked BAD, schema remains 1, activation aborted.
- irreversible migration: rejected before the script runs, B marked BAD.
- migration backup exists.
- user data and settings survive migration and rollback.
