# Dev / lab / prod image identity

## Profiles

Duranium understands three image profiles:

- `dev`: developer workflow, explicit development override allowed.
- `lab`: interactive experiment bench.
- `prod`: production; no development conveniences.

The running profile is read from `/etc/duranium/profile`; the artifact profile
comes from the signed manifest.

## Compatibility rule

Exact match is always accepted.

A mismatch is accepted only when all of the following are true:

1. the running profile is `dev`;
2. `/etc/duranium` sets `DURANIUM_DEV_OVERRIDE=1`;
3. the operator passes `--allow-profile-mismatch`.

Therefore:

| Running profile | Artifact profile | Result |
|---|---|---|
| prod | prod | accepted |
| prod | lab | rejected |
| prod | dev | rejected |
| prod | any mismatch with `--allow-profile-mismatch` | rejected |
| lab | lab | accepted |
| lab | dev/prod | rejected unless exact |
| dev | dev | accepted |
| dev | lab/prod with override flag + config | accepted |

Production never silently inherits development conveniences. The dev override
flag cannot be enabled by a command-line argument alone; it requires the image
configuration to opt in, and the running profile must be `dev`.

## Architecture

The artifact `architecture` must equal the running architecture (`uname -m`,
normally `aarch64`). This check has no override.

## Hardware target

The artifact `hardware_target` must equal `/etc/duranium/hardware-target`.
Examples:

- `qemu-aarch64-virt` for the QEMU fixture;
- `generic-aarch64` for a generic image;
- `krane-mt8183` for the real Lenovo Duet target.

This check has no override. A Krane image is not installable on QEMU or a
different board merely by changing the profile.

## Tests

Unit and QEMU tests verify:

- prod rejects lab and dev updates;
- prod cannot use the development override;
- dev rejects a mismatched profile without the explicit flag;
- dev accepts with the override flag + config;
- architecture mismatch rejected;
- hardware-target mismatch rejected.
