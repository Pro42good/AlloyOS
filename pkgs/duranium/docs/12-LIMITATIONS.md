# Known limitations (V1)

Duranium V1 is a proof, not a polished product. These are deliberate limits.

## Boot chain

- **One systemd-boot binary.** It lives on BOOT and is not A/B duplicated. If
  the bootloader itself is destroyed, recovery cannot boot. A future version
  should install a fallback loader or a small redundant boot manager.
- **One shared BOOT FAT.** Metadata, kernels, initramfs, and entries share the
  ESP. FAT has no journal; dual metadata copies and rename+sync are best-effort,
  not a filesystem-level transaction.
- **systemd-boot is the only implemented bootloader backend.** The core logic
  is behind a backend interface, but Krane/Depthcharge/U-Boot backends are not
  implemented in V1.
- **Boot counting semantics are systemd-boot-specific.** The entry filename is
  the attempt counter. A different bootloader backend must provide equivalent
  behavior or the core must implement its own pre-boot selector.

## Fixture vs real Alloy

- The automated QEMU acceptance suite boots a minimal Alpine/BusyBox fixture,
  not the full Alloy Core systemd userland. It uses the real kernel, UEFI,
  systemd-boot, GPT, ext4, read-only mounts, STATE binds, and update logic.
- A real-Core systemd overlay-root smoke test has not been completed. The
  adapter in `contrib/alloy-core/` documents the required overlay and STATE
  bind setup, but it is not part of the green V1 suite. The built-in health
  check also expects a directly read-only `/`; an overlay-root adapter must
  disable that check and verify the lower SYSTEM mount is read-only instead.
- The boot-confirmation handshake is enforced by `mark-good` and exercised
  by the fixture's PID 1 (`duranium boot-confirm`). The **sign-in gate**
  (`duranium session-confirm` with `DURANIUM_REQUIRE_SESSION=1`) is a stub
  saved for later: the API is implemented and unit-tested, but no GUI calls
  it and the default does not require it. Crash detection is journal-based
  (`duranium session-crash` reports plus unclean-shutdown detection at the
  next `boot-confirm`); there is no watchdog or core-dump integration.
- The minimal STATE allowlist is `/home`, `/var/lib/alloy`, and `/etc/alloy`.
  Real Core integration will need NetworkManager connections, SSH host keys,
  Bluetooth pairings, and possibly other explicit paths, each with a migration
  story.

## Update mechanism

- No network downloads. Artifacts are local directories.
- No delta updates, compression other than optional gzip payload, or
  streaming.
- No artifact tar/container format; the directory format is the V1 interface.
- Slot sizes are fixed. There is no grow/shrink or filesystem resize.
- A full payload image is written on every update.
- No secure boot, signed boot metadata, or bootloader verification.
- Metadata checksums are integrity checks, not signatures. Root access to BOOT
  can change boot selection.

## STATE

- STATE is not encrypted.
- Only a minimal allowlist persists.
- Migration backups are tar files in STATE; very large STATE trees are not
  optimized.
- Irreversible migrations are always rejected while rollback is expected; a
  future "commit and discard rollback" workflow is not implemented.
- Migrations are not transactional at the filesystem level; failures abort
  activation and leave a backup, but arbitrary third-party migration scripts
  can still be poorly behaved.

## Recovery

- CLI only. No GUI, no automatic repair heuristics, no user-facing recovery.
- Recovery kernel/initramfs are on BOOT, so recovery depends on BOOT being
  readable even though it does not depend on A/B.
- Factory reset OS mode invalidates slots and boot artifacts; it does not
  automatically reinstall an image.

## Profiles and policy

- The dev override is a simple config flag plus CLI flag. It is not a signed
  developer-mode attestation.
- Architecture/hardware checks are exact string matches.
- APK is intentionally excluded from production updates. There is no live
  package-management path.

## Testing

- Test keys are ephemeral and generated during fixture construction; they are
  not production keys.
- The QEMU suite requires Docker, QEMU, aarch64 EDK2, and an existing Alloy
  baseline image for kernel/systemd-boot extraction.
- QEMU/HVF tests are macOS/arm64-oriented; Linux KVM and TCG paths are
  implemented but not part of the recorded results.
- A real hardware/Krane test is not part of V1.

## Not implemented on purpose

Chromium, SystemUI, Waydroid, ASHT, GUI update tools, polished user recovery,
network update services, and changes to the frozen Alloy Core build.

## Root-image hashing

- The root image hash (`image_sha256` over `image_size`) is verified only at
  install read-back and in the initramfs before the slot is mounted. It is
  never verified from the booted OS: a mounted ext4's raw bytes are not a
  function of the installed image (journal/superblock buffers in the
  block-device page cache; read-write mounts rewrite superblock fields and
  all backup superblocks).
- PENDING slots are always root-hashed pre-mount; GOOD slots only when
  `DURANIUM_VERIFY_ROOT_ON_BOOT=1`.
- This is corruption detection, not anti-tamper: the metadata that carries
  the digest is checksummed but unsigned, so a local root can rewrite both
  the image and its digest. Real tamper resistance needs dm-verity or signed
  boot metadata.
