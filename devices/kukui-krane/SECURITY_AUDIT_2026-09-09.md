# Security Audit — Kukui-Krane — 2026-09-09

## Summary
- Critical: 0
- High: 3
- Medium: 4
- Low: 3
- Informational: 3

## Critical
None found.

## High

### [scripts/run-pmos-vm.sh:10,45](scripts/run-pmos-vm.sh#L10) and [scripts/run-qemu-arm.sh:57](scripts/run-qemu-arm.sh#L57) — SSH port-forwarded to all network interfaces
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-668
- **Issue:** `hostfwd=tcp::2222-:22` (no `127.0.0.1` bind) exposes the VM's SSH to every interface on the host. `run-qemu-headless.sh` correctly uses `hostfwd=tcp:127.0.0.1:"$PORT"-:22`.
- **Why it matters:** Anyone on the same network can connect to port 2222 and attempt login against the VM's hardcoded password. On shared or public networks this is a direct exposure vector.
- **Remediation:** Change both scripts to `hostfwd=tcp:127.0.0.1:2222-:22` to match `run-qemu-headless.sh`.

### [alloy/build-core.sh:30,33-38](alloy/build-core.sh#L30) — SSH host-key verification disabled across all automation
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-295
- **Issue:** Every SSH/SCP call uses `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`, repeated in `build-profile.sh`, `regression-test.sh`, `quiescence-test.sh`, `collect-metrics.sh`, and `measure-boot.sh`. The scripts also pipe the password directly to sudo (`printf '147147\n' | sudo -S`).
- **Why it matters:** Without host-key verification, a rogue SSH server on the forwarded port could intercept credentials and commands. The hardcoded password `147147` is then exposed to any MITM. Even in a local-only context, this establishes a bad pattern that propagates if the scripts are reused.
- **Remediation:** Generate a known host key at build time, write it to a per-repo `known_hosts` file, and pass `-o UserKnownHostsFile=<repo>/.ssh/known_hosts` instead of `/dev/null`. For the password: use SSH key-only auth from stage 00 onward (the scripts already install the host key — just gate password auth on that one `ssh-run.exp` call and remove the `sudo -S` password pipe).

### [scripts/pmbootstrap-docker.sh:30-33](scripts/pmbootstrap-docker.sh#L30) — Docker container runs with `--privileged`
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-250
- **Issue:** The build container is created with `docker run --privileged`, which grants access to all host devices, disables seccomp/AppArmor, and allows mount operations.
- **Why it matters:** A compromised or misbehaving build step could modify the host filesystem, load kernel modules, or escape the container entirely. The `--privileged` flag is the broadest privilege escalation path in Docker.
- **Remediation:** Replace `--privileged` with the minimal capabilities needed: `--cap-add SYS_ADMIN --device /dev/loop-control` and volume-mount only the required paths. pmbootstrap needs chroot/loop access, not full device enumeration.

## Medium

### [scripts/download-kukui.sh:10-21](scripts/download-kukui.sh#L10) — Downloaded image not automatically verified
- **OWASP:** A08:2021 Software and Data Integrity Failures  **CWE:** CWE-345
- **Issue:** The script downloads the official Krane image and fetches the `.sha256` file, but prints them side-by-side for manual comparison instead of running `shasum -a 256 -c` to verify automatically.
- **Why it matters:** A corrupted or tampered download could be used as-is. The decompressed image is eventually booted and flashed to real hardware (§15 of README). Manual verification is easily skipped.
- **Remediation:** After download, run `shasum -a 256 -c "$FILE.sha256"` (or equivalent) and `exit 1` on mismatch.

### [alloy/steps/05-swap.sh:4-8](alloy/steps/05-swap.sh#L4) — Swap file created with `chmod 600` but no `fallocate` integrity
- **OWASP:** A04:2021 Insecure Design  **CWE:** CWE-732
- **Issue:** `fallocate -l 2G /swapfile` preallocates space but the file contents are whatever was on disk. `mkswap` then overwrites the header. The `chmod 600` is correct, but the script runs as root inside a VM where the filesystem is single-user.
- **Why it matters:** Low practical risk in a local VM, but in a multi-user context a swap file created with `fallocate` on certain filesystems can leak stale data from deleted files. The `chmod 600` mitigates this for single-user VMs.
- **Remediation:** Use `dd if=/dev/zero of=/swapfile bs=1M count=2048` instead of `fallocate` to guarantee clean swap contents, or document the assumption that this is single-user.

### [scripts/run-pmos-vm.sh:41](scripts/run-pmos-vm.sh#L41) and [scripts/run-qemu-arm.sh:59](scripts/run-qemu-arm.sh#L59) — Unquoted `$SERIAL_ARGS` / `$UEFI_ARGS` variable expansion
- **OWASP:** A03:2021 Injection  **CWE:** CWE-78
- **Issue:** `$SERIAL_ARGS` and `$UEFI_ARGS` are expanded without quotes in the `exec qemu-system-aarch64` command. If any value contained spaces or glob characters, word splitting would break the command.
- **Why it matters:** In the current code the values are safe strings, but this is fragile — a future edit that introduces a space in a path or argument would silently break or inject arguments. Shell-check standards flag this pattern.
- **Remediation:** Use `eval exec qemu-system-aarch64 ... $SERIAL_ARGS` (with proper quoting in the variable) or refactor to use arrays (bash) or explicit conditional argument lists.

### [alloy/build-core.sh:35](alloy/build-core.sh#L35) — Password piped directly to sudo via printf
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-522
- **Issue:** `printf '147147\n' | sudo -S -p '' sh -c '...'` passes the password on stdin to sudo. The password is also visible in the script source and in the process list (`ps aux` shows `sudo` with the piped command).
- **Why it matters:** The password is exposed in shell history, process listings, and the script file itself. If the repo is shared or pushed to a public remote, the credential leaks.
- **Remediation:** The SSH key is already installed in the same step — remove the sudo password pipe entirely and use key-based `ssh root@` for all subsequent commands. The `ssh-run.exp` password-auth call is the only one that should use the password.

## Low

### [scripts/pmbootstrap-docker.sh:41](scripts/pmbootstrap-docker.sh#L41) — Sudoers NOPASSWD for build user
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-250
- **Issue:** `echo 'pmos ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/pmos` grants the `pmos` user passwordless root inside the Docker container.
- **Why it matters:** The container is already `--privileged`, so this is additive rather than a separate escalation. However, if the privilege escalation is ever scoped down (per finding above), this sudoers entry would remain as a backdoor.
- **Remediation:** Limit sudoers to the specific commands pmbootstrap needs (`apk`, `chroot`, `losetup`, `mount`, `umount`, `mknod`) instead of `ALL`.

### [alloy/regression-test.sh:9](alloy/regression-test.sh#L9) and [alloy/quiescence-test.sh:9](alloy/quiescence-test.sh#L9) — Predictable temp directory pattern
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-377
- **Issue:** `mktemp -d /var/folders/.../reg.XXXX` uses a 4-character random suffix. While the parent path is macOS-managed, the `XXXX` pattern is low-entropy.
- **Why it matters:** A local attacker who can predict the directory name could create a symlink to intercept file writes during the test. In practice, macOS temp directories are per-user and permissions-protected, making this low risk.
- **Remediation:** Use `mktemp -d` with no template (uses system default, higher entropy) or at least 8+ random characters.

### [scripts/run-qemu-arm.sh](scripts/run-qemu-arm.sh) — Deprecated script still executable with weaker security posture
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-1188
- **Issue:** `run-qemu-arm.sh` is documented as superseded by `run-pmos-vm.sh` but remains in the repo and is executable. It binds SSH to all interfaces and has different firmware path logic.
- **Why it matters:** A developer unfamiliar with the project might run the wrong script, getting the less-secure configuration (SSH on 0.0.0.0).
- **Remediation:** Delete the script or add a prominent warning at the top that it is deprecated, pointing to `run-pmos-vm.sh`.

## Informational

### [alloy/keys/](alloy/keys/) — APK signing keys committed to the repository
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-321
- **Issue:** 19 public APK signing keys are committed under `alloy/keys/`. These are Alpine/postmarketOS package signing public keys, not private keys.
- **Why it matters:** Public keys are not secrets, but committing them means the trust anchor cannot be rotated without a repo change. If the upstream keyset changes, builds using the committed keys could fail silently or accept packages signed by a revoked key.
- **Remediation:** Document the keyset version/fingerprint in a comment. Consider fetching keys from a canonical source at build time instead of vendoring them.

### [alloy/build-core.sh:15](alloy/build-core.sh#L15) — SSH public key read from `~/.ssh/id_ed25519.pub` without existence check
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-200
- **Issue:** `PUB="$(cat "$HOME/.ssh/id_ed25519.pub")"` reads the user's public key for installation into the VM. If the file doesn't exist, `set -eu` causes the script to fail with an unhelpful error.
- **Why it matters:** Informational — the key is a public key and not a secret, but the missing error message is a usability issue.
- **Remediation:** Add `[ -f "$HOME/.ssh/id_ed25519.pub" ] || { echo "error: no SSH key found at ~/.ssh/id_ed25519.pub"; exit 1; }` before the `cat`.

### [alloy/quiescence-test.sh:73-81](alloy/quiescence-test.sh#L73) — Inline Python code block for CPU calculation
- **OWASP:** A03:2021 Injection  **CWE:** CWE-94
- **Issue:** A heredoc Python script is interpolated with shell variables (`$IRQ_RATE`, `$CPU_PCT`, `$BUSY_PCT`). The values come from the VM's `/proc` output and are numeric, but no explicit sanitization is performed before shell expansion.
- **Why it matters:** The values are derived from `awk`/`python3` on numeric proc files, so injection is extremely unlikely. However, if the VM returned a malicious string, it could break the Python syntax or inject code.
- **Remediation:** Pass the values as arguments (`python3 - "$VAR" <<'PYEOF'` with `sys.argv[1]`) instead of interpolating into the heredoc body, which is already done for some variables but not all.

---

*Report generated 2026-09-09. This is a point-in-time record — re-run the audit after fixing issues to confirm remediation.*

---

## Remediation record — 2026-09-09 (same day)

| ID | Finding | Status | Fix |
|---|---|---|---|
| HIGH-1 | SSH forwarded on all interfaces | **FIXED** | `run-pmos-vm.sh` + `run-qemu-arm.sh` now bind `hostfwd=tcp:127.0.0.1:2222-:22`; both runners also refactored to positional `set --` args (fixes MED-3) |
| HIGH-2 | Host-key verification disabled + password exposure | **FIXED** | `alloy/known_hosts` pins the guest host keys (TOFU once, local VM, documented header); all automation uses `StrictHostKeyChecking=yes` + pinned file; password now travels only via `PMOS_PASS` env through the expect helper (never argv, never pipes); sudo prompt answered in-session (`sudo sh -c` on the tty) |
| HIGH-3 | `--privileged` container | **FIXED** | `--cap-add SYS_ADMIN` + `/dev/loop-control` + `/dev/loop0-7` only; note: the reproducible ALLOY build path (`alloy/build-core.sh`) doesn't use Docker at all |
| MED-1 | Download not auto-verified | **FIXED** | `download-kukui.sh` runs `shasum -a 256 -c` and exits 1 on mismatch (removes the file) |
| MED-2 | Swapfile via bare `fallocate` | **FIXED** | `alloy/steps/05-swap.sh` dd-zeros the 2 GB before `mkswap`; the shipped `alloy-core.qcow2` was re-zeroed in place — the stale-data region compressed away (884 → 604 → **349 MiB**) |
| MED-3 | Unquoted `$SERIAL_ARGS`/`$UEFI_ARGS` | **FIXED** | positional `set --` accumulation, no word-splitting paths |
| MED-4 | Password via `printf \| sudo -S` | **FIXED** | removed; see HIGH-2 (expect answers the sudo prompt in-session) |
| LOW-1 | Sudoers NOPASSWD:ALL | **FIXED** | scoped to pmbootstrap's command set (`apk`, `chroot`, `losetup`, `mount`, `umount`, `mkfs.*`, `mknod`, `mkinitfs`) |
| LOW-2 | 4-char mktemp suffix | **FIXED** | 8-char random suffix (`reg.XXXXXXXX` / `qui.XXXXXXXX`) |
| LOW-3 | Deprecated `run-qemu-arm.sh` | **FIXED** | prominent deprecation banner + hardened anyway (kept for reference, not deleted) |
| INFO-1 | APK keys committed | **DOCUMENTED** | `alloy/keys/README.md`: provenance (pmbootstrap chroot, 2026-09-08), per-key sha256 fingerprints, rotation procedure (add, never remove) |
| INFO-2 | PUB key without existence check | **FIXED** | explicit `[ -f … ]` guard with clear error |
| INFO-3 | Python heredoc interpolation | **FIXED** | VM-derived values sanitized (`tr -cd "0-9."`) at source; heredocs take values via argv |

**Remediation-run learnings (added to the gotcha graveyard):**

1. Harness path depth differs: `baselines/0001/*` needs `../..` to the repo,
   `alloy/*` needs `../` — a wrong-depth `known_hosts` path silently fails
   every connection under `StrictHostKeyChecking=yes` (looks like "never
   booted").
2. Perl one-liner replacements interpolate `@` (e.g. `root@127.0.0.1` →
   `root.0.0.1`) and mangle quotes — use python/heredocs for scripted edits.
3. Boot-poll timeouts must cover cold-cache first boots; a failed gate must
   power off its VM and clean its scratch dir (the first "never booted" left
   a zombie holding ports 2222/4445).

**Post-fix validation:** dev profile — REGRESSION ALL PASS + QUIESCENCE ALL
PASS under the hardened harness (pinned host key, sanitized inputs); rebuilt
Core re-zeroed + re-gated — REGRESSION ALL PASS + QUIESCENCE ALL PASS, now
349 MiB compressed.
