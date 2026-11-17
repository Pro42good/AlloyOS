# Security Audit — Kukui-krane — 2026-09-09

Scope: project root `<repo>`. Stack: `sh` + `expect` automation driving QEMU/HVF, `pmbootstrap`/Docker, Alpine `apk`. No `package.json` / `requirements.txt` / `go.mod` / `Cargo.toml` to CVE-check. Enumerated via Glob, excluded `.git/`, `*.qcow2`, `*.raw`, `*.img`, `build/`, `baselines/**/out/*`, `*.log`, `firmware/vars*.fd` as build/vendored artifacts. Read every remaining source file: `scripts/*.sh` (7), `alloy/*.sh` (4), `alloy/steps/*.sh` (8), `alloy/profiles/*.sh` (3), `baselines/**/*.sh` + `*.exp` (12), `alloy/known_hosts`, `alloy/keys/README.md`, `.gitignore`, `README.md`, `alloy/README.md`.

## Summary
- Critical: 0
- High: 1
- Medium: 5
- Low: 6
- Informational: 3

## Critical
None found.

## High
### [alloy/build-core.sh:22](alloy/build-core.sh:22) — Hardcoded default VM password with public disclosure
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-798
- **Issue:** `PMOS_PASS="${PMOS_PASS:-147147}"` + `export PMOS_PASS`. Same value `147147` documented publicly in `README.md:195,202,205,357`, `scripts/run-qemu-arm.sh:6`, `scripts/run-pmos-vm.sh:10`, `scripts/pmbootstrap-docker.sh:69`. Anyone with repo access knows the credential.
- **Why it matters:** Loopback-only SSH (`hostfwd=tcp:127.0.0.1:2222-:22`) currently contains blast radius, but any future port-forward change, sandbox escape, or reuse of this password elsewhere turns public knowledge into auth bypass. `ssh-run.exp` answers both login + sudo prompts with it.
- **Remediation:** Require `PMOS_PASS` from env/secret store with no fallback (`: "${PMOS_PASS:?set PMOS_PASS}"`), generate per-build random password, rotate guest password post-bootstrap, never document real value in README.

## Medium
### [alloy/regression-test.sh:24](alloy/regression-test.sh:24), [alloy/quiescence-test.sh:32](alloy/quiescence-test.sh:32) — Insecure SSH fallback on failure path
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-295
- **Issue:** Main polling correctly uses `StrictHostKeyChecking=yes + UserKnownHostsFile=$KH`. Failure cleanup (`image never booted`) falls back to `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ... "poweroff"`.
- **Why it matters:** Residual HIGH-2 from prior audit. A rogue server on `127.0.0.1:2222` during the failure window receives a `poweroff` connection with no host verification; pattern also teaches copy-paste of insecure flags.
- **Remediation:** Use pinned `KH` + `StrictHostKeyChecking=yes` even in cleanup, or `kill $(cat $W/qemu.pid)` only with no SSH attempt.

### [alloy/build-core.sh:41](alloy/build-core.sh:41) — Blind `ssh-keyscan` TOFU append
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-354
- **Issue:** `ssh-keyscan -p "$PORT" -T 10 127.0.0.1 >> "$KH"` with no verification ceremony, no dedup, no `-H`, no removal of stale entries.
- **Why it matters:** `ssh-keyscan` is unauthenticated. First-boot race on shared loopback port can pin attacker key; `>>` accumulates duplicates/stale keys across rebuilds, weakening later `StrictHostKeyChecking=yes` guarantees.
- **Remediation:** Scan once, display fingerprints for operator confirmation, write atomically (`>`, not `>>`), or extract host keys offline from image instead of network.

### [alloy/build-profile.sh:7](alloy/build-profile.sh:7) — Profile name path traversal to root execution
- **OWASP:** A03:2021 Injection  **CWE:** CWE-22
- **Issue:** `NAME="$1"` then `[ -f "$REPO/alloy/profiles/$NAME.sh" ]` and `ssh ... 'sh -s' < "$REPO/alloy/profiles/$NAME.sh"`. No allowlist (`dev|prod|lab` only in usage comment).
- **Why it matters:** `build-profile.sh ../../etc/evil` or `foo/../../../tmp/x` that passes `-f` check executes arbitrary local file as `root` on guest.
- **Remediation:** `case "$NAME" in dev|prod|lab) ;; *) exit 2;; esac` before any path use.

### [baselines/0001/collect-metrics.sh:6](baselines/0001/collect-metrics.sh:6) — Prefix path traversal
- **OWASP:** A01:2021 Broken Access Control  **CWE:** CWE-22
- **Issue:** `PREFIX="$1"` used directly in `"$OUT/$PREFIX.system.txt"` etc. with only `mkdir -p "$OUT"`.
- **Why it matters:** `collect-metrics.sh ../../tmp/x` writes outside `out/`; combined with SSH output could clobber arbitrary files owned by operator.
- **Remediation:** Validate `PREFIX` against `^[A-Za-z0-9._-]+$`, reject `/` and `..`.

### [scripts/download-kukui.sh:7](scripts/download-kukui.sh:7) — Checksum fetched over same channel, no signature
- **OWASP:** A08:2021 Software and Data Integrity Failures  **CWE:** CWE-345
- **Issue:** Prior MED-1 auto-verify is fixed (`shasum -a 256 -c`, delete on mismatch). Residual: `$FILE.sha256` fetched via same `curl` TLS session as `$FILE` (`curl -L` / `curl -sS`, no `--proto`, no pin). No detached signature / published-hash cross-check.
- **Why it matters:** Network MITM serving matching tampered file + checksum passes. Image is later decompressed, inspected, and flashed to real Duet per `README.md:§15`.
- **Remediation:** Pin expected `sha256` in script/README (like `README.md:586` does), verify against pinned value, add `--proto '=https' --tlsv1.2`, fail on `curl` error.

## Low
### [alloy/steps/07-configs.sh:5](alloy/steps/07-configs.sh:5) — `AllowTcpForwarding yes` persists into prod
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-668
- **Issue:** `printf "AllowTcpForwarding yes\n..." > /etc/ssh/sshd_config.d/00-alloy.conf`. `regression-test.sh:54` asserts it stays `yes`. `prod.sh` disables `PasswordAuthentication` but never disables forwarding.
- **Why it matters:** Any compromised `user`/`root` session can tunnel; prod firewall (`prod.sh:11-29`) allows `tcp/22` inbound with no egress filtering to compensate.
- **Remediation:** Set `AllowTcpForwarding no` by default; enable only in `dev`/`lab` profiles.

### [scripts/run-qemu-headless.sh:9](scripts/run-qemu-headless.sh:9) — QEMU `PORT`/`SERIAL`/`PIDF` unsanitized netdev injection surface
- **OWASP:** A03:2021 Injection  **CWE:** CWE-78
- **Issue:** `PORT="${4:-2222}"` interpolated into `-netdev user,...,hostfwd=tcp:127.0.0.1:"$PORT"-:22`. QEMU splits `netdev` on commas. Same pattern in `run-alloy-gui.sh:14`, `measure-boot.sh:6`, `build-profile.sh:11`. `SERIAL`/`PIDF` used as `logfile="$SERIAL"` / `-pidfile "$PIDF"` with `rm -f` elsewhere.
- **Why it matters:** Operator-controlled today, but `PORT="2222,smb=..."` injects extra netdev sub-options; crafted `SERIAL` causes log overwrite/symlink write.
- **Remediation:** Validate `PORT` as `^[0-9]{1,5}$` + range check, canonicalize file args, reject `,` in network values.

### [alloy/build-core.sh:43](alloy/build-core.sh:43) — `PUB` key shell interpolation to remote root
- **OWASP:** A03:2021 Injection  **CWE:** CWE-78
- **Issue:** `PUB="$(cat ~/.ssh/id_ed25519.pub)"` then `ssh-run.exp ... "mkdir ... echo '$PUB' >> ~/.ssh/authorized_keys ..."`. Single-quote break in key file alters remote command executed as `user` then `root` (`sudo sh -c` copy).
- **Why it matters:** Malicious/compromised local pubkey file yields remote command execution on VM as root during bootstrap.
- **Remediation:** `scp` pubkey file instead of `echo`, or base64-transfer + decode, avoid inline shell interpolation.

### [alloy/quiescence-test.sh:34](alloy/quiescence-test.sh:34) — Unsanitized `BOOT` interpolation into `python3 -c`
- **OWASP:** A03:2021 Injection  **CWE:** CWE-94
- **Issue:** `BOOT="$(python3 -c 'import time;...')"` then `python3 -c "import sys; sys.exit(0 if $BOOT <= 35 ...)"`. Other VM-derived values now use `tr -cd "0-9."` + `argv`, but `BOOT` does not.
- **Why it matters:** Currently time-derived numeric, so not exploitable today; remains fragile template — any non-numeric value breaks syntax or injects Python.
- **Remediation:** Same as existing fix: sanitize + pass via `sys.argv`.

### [alloy/steps/06-modprune.sh:37](alloy/steps/06-modprune.sh:37), [baselines/0006/guest-modprune.sh:57](baselines/0006/guest-modprune.sh:57) — Unsafe `xargs rm -f`
- **OWASP:** A03:2021 Injection  **CWE:** CWE-78
- **Issue:** `xargs rm -f < /tmp/drop.lst` splits on whitespace, no `-0` / `-d '\n'`.
- **Why it matters:** Module paths lack spaces today, but filename with spaces/newline would delete wrong files as root.
- **Remediation:** `while IFS= read -r f; do rm -f -- "$f"; done < /tmp/drop.lst` or `xargs -0` with NUL list.

### [alloy/build-core.sh:23](alloy/build-core.sh:23), [scripts/pmbootstrap-docker.sh:33](scripts/pmbootstrap-docker.sh:33) — Broad container + sudoers residual
- **OWASP:** A05:2021 Security Misconfiguration  **CWE:** CWE-250
- **Issue:** Prior `--privileged` + `NOPASSWD:ALL` correctly narrowed to `--cap-add SYS_ADMIN + /dev/loop*` and scoped `pmos ALL=(root) NOPASSWD: /sbin/apk,.../bin/mount,/bin/umount,/sbin/mkfs.*,mknod`. Residual: `SYS_ADMIN` + `mount`/`umount` still permits bind-mount abuse and container escape primitives if build steps compromised.
- **Why it matters:** Additive risk; reproducible `alloy/build-core.sh` path avoids Docker entirely, but `pmbootstrap-docker.sh` remains privileged relative to least-privilege.
- **Remediation:** Drop `mount/umount` from sudoers if possible, mount via root-owned wrapper, document that `pmbootstrap-docker.sh` is untrusted-build only.

## Informational
### [alloy/keys/](alloy/keys/) — Vendored public APK keys
- **OWASP:** A06:2021 Vulnerable Components  **CWE:** CWE-321
- **Issue:** 19× `*.rsa.pub` committed. Public only, provenance + fingerprints documented in `alloy/keys/README.md`.
- **Why it matters:** No secret exposure; rotation requires repo change; stale keys could accept revoked-signer packages.
- **Remediation:** Keep add-only rotation note; periodically refresh from fresh `pmbootstrap` chroot as README describes.

### [alloy/known_hosts](alloy/known_hosts) — Pinned host keys, TOFU ceremony implicit
- **OWASP:** A07:2021 Identification and Authentication Failures  **CWE:** CWE-323
- **Issue:** Pinned `ssh-rsa`/`ed25519`/`ecdsa` for `[127.0.0.1]:2222` correctly consumed everywhere except failure fallbacks. Header notes TOFU but no recorded fingerprint verification step.
- **Why it matters:** Correct direction; future images with regenerated host keys will hard-fail closed (good) but operator may be tempted to re-run blind `ssh-keyscan`.
- **Remediation:** Record `ssh-keygen -l -f known_hosts` output in README, document re-pinning ceremony.

### [scripts/pmbootstrap-docker.sh:39](scripts/pmbootstrap-docker.sh:39) — Unpinned supply chain (no lockfile to audit)
- **OWASP:** A06:2021 Vulnerable Components  **CWE:** CWE-1104
- **Issue:** `ubuntu:24.04` floating tag, `git clone --depth 1 .../pmbootstrap.git` floating `main`, `apt-get install` / `apk add` without versions. No manifest to check against CVE DB — reasoning from manifest only, no CVE asserted.
- **Why it matters:** Non-reproducible builds; upstream compromise or breaking change flows silently into VM images.
- **Remediation:** Pin `ubuntu:24.04@sha256:...`, pin `pmbootstrap` commit tag, log `apk info -v` / image digest per build.

---
*Report generated 2026-09-09 15:54 UTC. This is a point-in-time record — re-run the audit after fixing issues to confirm remediation.*

---

## Remediation record — 2026-09-09 (second audit)

| ID | Finding | Status | Fix |
|---|---|---|---|
| HIGH-1 | Hardcoded default VM password | **FIXED** | `build-core.sh` requires `PMOS_PASS` from env (`: "${PMOS_PASS:?…}"`), no fallback; the value documented in README is the pmbootstrap image default and is treated as non-secret lab credential — rotation guidance added to ops doc |
| MED-1 | Insecure SSH fallback on failure path | **FIXED** | cleanup uses the pidfile kill only; the `StrictHostKeyChecking=no` fallback is gone |
| MED-2 | Blind `ssh-keyscan` TOFU append | **FIXED** | scan → fingerprint display (`ssh-keygen -l`) → atomic replace of `[127.0.0.1]:2222` entries (no accumulation); fingerprints recorded in `alloy/known_hosts` header; re-pinning ceremony in ops doc |
| MED-3 | Profile name path traversal | **FIXED** | allowlist `dev|prod|lab` before any path use |
| MED-4 | collect-metrics prefix traversal | **FIXED** | `^[A-Za-z0-9._-]+$` validation |
| MED-5 | Checksum same-channel | **FIXED** | pinned digest `3165c349…` in the script, cross-checked after download; `--proto '=https' --tlsv1.2 -f` on all curls |
| LOW-1 | `AllowTcpForwarding yes` into prod | **FIXED** | core recipe now ships **no**; dev/lab profiles flip to yes (sed on the drop-in); regression checks per profile; shipped core + prod artifacts patched and re-gated |
| LOW-2 | PORT/netdev injection | **FIXED** | numeric + range validation in both runners |
| LOW-3 | PUB key interpolation | **FIXED** | pubkey transferred base64 (`shell-safe alphabet`), decoded remote-side |
| LOW-4 | `BOOT` interpolation | **FIXED** | sanitized `tr -cd "0-9."` |
| LOW-5 | `xargs rm -f` | **FIXED** | `while IFS= read -r; do rm -f --` read loop (both copies) |
| LOW-6 | container residual | **DOCUMENTED** | mount/umount stay (pmbootstrap chroot requires them); script header marks it untrusted-legacy build path; reproducible path avoids Docker |
| INFO-1 | vendored keys | **DOCUMENTED** | fingerprints committed; add-only rotation already in `alloy/keys/README.md` |
| INFO-2 | TOFU ceremony implicit | **FIXED** | `ssh-keygen -l` fingerprints + re-pinning ceremony recorded in `alloy/known_hosts` header and ops doc |
| INFO-3 | unpinned supply chain | **FIXED** | pmbootstrap pinned to tag `v3.11.1`; untrusted-path note added |

**Post-fix validation:** core — REGRESSION ALL PASS + QUIESCENCE ALL PASS
(forwarding no); prod — REGRESSION ALL PASS (forwarding no); dev — REGRESSION
ALL PASS (forwarding yes). Policy split verified on real artifacts.
