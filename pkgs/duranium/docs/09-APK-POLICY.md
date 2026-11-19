# APK and the immutable production update model

APK remains useful for **constructing** Alloy images. It is not the production
update mechanism.

## Production model

```
packages
  → image build
  → immutable ext4/EROFS system image
  → signed Duranium artifact
  → write inactive slot
  → verify
  → boot PENDING
  → health check
  → explicit mark-good
```

Production Duranium does not run:

```
apk upgrade
```

to mutate the currently running system. Doing so would violate the core
invariant that the running system is never modified in place and would bypass
the A/B rollback model.

## What APK is allowed to do

- Build the root filesystem during image construction.
- Populate a development/lab image outside the production update path.
- Construct an updated system image in CI or a build host.

The image is then frozen, hashed, signed, and delivered as a Duranium artifact.

## Developer workflow

A developer may build a new image with APK, boot it in the lab profile, and
install it as a signed artifact. The update path is still:

```
new image → inactive slot → verify → PENDING → mark-good
```

not:

```
apk upgrade on the live root
```

## Enforcement in V1

- The runtime updater, recovery, and initramfs contain no `apk add/upgrade/del`
  calls.
- The runtime updater contains no network download path.
- A unit test (`tests/unit/09-policy.sh`) fails if APK mutation or `curl`/`wget`
  appears in the runtime code.
- Documentation and tests describe packages as build inputs.

## If you need live package changes

Do not add them to the production updater. Build a new image and ship it as an
A/B update. This keeps the active slot immutable and rollback meaningful.
