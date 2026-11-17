# Update manifest and artifact format

## Artifact directory

```
artifact/
  manifest.txt        canonical key=value manifest (the signed bytes)
  manifest.sig        base64 of the raw Ed25519 signature over manifest.txt
  system.img          root filesystem image
  boot/vmlinuz        slot kernel
  boot/initramfs      slot initramfs
```

`system.img` may be gzip-compressed if the manifest says
`system_image_compression=gzip`; the hash is always over the uncompressed image.
V1 tests use `none`.

## Manifest fields (fixed order)

```
duranium_manifest=1
format_version=1
alloy_version=1.0
build_id=A-v1
architecture=aarch64
profile=prod
hardware_target=qemu-aarch64-virt
system_image=system.img
system_image_size=134217728
system_image_sha256=<64 hex>
system_image_compression=none
boot_kernel=boot/vmlinuz
boot_kernel_sha256=<64 hex>
boot_initramfs=boot/initramfs
boot_initramfs_sha256=<64 hex>
state_schema_required=2
state_schema_backward_compatible=1
rollback_compatible=1
key_id=test-key
created_at=2026-11-17T00:00:00Z
```

The parser requires exactly these fields in this order, rejects unknown or
duplicate fields, and rejects unsupported format versions.

## Signing

- Algorithm: **Ed25519** via OpenSSL (`openssl pkeyutl -sign -rawin`).
- Hash: **SHA-256** for the payload and boot artifacts.
- The signature covers the exact bytes of `manifest.txt`.
- `manifest.sig` is the base64 encoding of the raw signature.
- Trusted public keys live in `/etc/duranium/keys/<key_id>.pub`.
- `key_id` is a safe identifier; unknown keys are rejected.
- No custom cryptography is implemented.

Generate and sign a test artifact:

```sh
duranium manifest keygen ./keys test-key
duranium manifest install-key ./keys/test-key.pub.pem test-key
duranium manifest sign ./artifact ./keys/test-key.priv.pem
duranium manifest verify ./artifact
```

`manifest verify` also enforces the system profile, architecture, hardware
target, and STATE schema compatibility. Use
`--allow-profile-mismatch` only in a dev/lab image with the explicit
development override enabled; prod always rejects it.

## Verification order

1. Manifest files exist and are regular files, not symlinks.
2. Manifest is canonical and every mandatory field is valid.
3. Signature verifies with the pinned key named by `key_id`.
4. Payload size and SHA-256 match.
5. Kernel and initramfs hashes match.
6. Profile, architecture, hardware target, and STATE schema are compatible.

Activation (writing `PENDING`) happens only after the updater also reads back
the written block device and hashes the exact payload length.

## Rejection cases covered by tests

- correct signature and payload: accepted
- modified payload: rejected
- modified manifest: rejected
- wrong signing key: rejected
- untrusted `key_id`: rejected
- wrong architecture: rejected
- wrong profile: rejected
- wrong hardware target: rejected
- unsupported manifest version: rejected
- non-canonical field order: rejected

## Why the manifest is not on STATE

The manifest is part of the local update artifact. A verified copy is placed
under BOOT for diagnostics, but boot selection and activation never trust a
manifest stored in STATE or on the artifact after verification. The updater
uses the in-memory verified values for the transaction.
