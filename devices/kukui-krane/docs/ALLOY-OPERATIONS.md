# ALLOY operations manual — day-2 with the floor

How to live with ALLOY-BASELINE-0007 / the rebuilt Core and its profiles:
booting, logging in, snapshotting, changing things safely, upgrading,
troubleshooting, and measuring. Everything here assumes the fixed VM geometry
(`-M virt,highmem=on -accel hvf -cpu host -smp 4 -m 4096`).

---

## 1. Booting

| Mode | Command | What you get |
|---|---|---|
| Headless (scripts) | `scripts/run-qemu-headless.sh <img> <serial.log> <pidfile> 2222 <vars.fd>` | daemonized, serial→logfile, SSH forwarded |
| GUI console (floor/profiles) | `nohup scripts/run-alloy-gui.sh [img] &` | cocoa window, virtio-gpu fb → tty1 console login; serial socket `nc 127.0.0.1 4445` |
| GUI lineage (Phosh) | `scripts/run-pmos-vm.sh` (gui\|headless\|serial) | the frozen ALLOY-GUI-0000 with the full UI stack |
| Direct kernel (lab-only) | `-kernel images/vmlinuz -initrd images/initramfs -append "root=/dev/vda2 rw console=…"` | skips the 5.5 s EDK2 stage — *not* comparable to measured boots |
| SSH tunnels | **dev/lab profiles only** (`AllowTcpForwarding yes`) — the core/prod floor ships forwarding **off** (SECURITY_AUDIT2 LOW-1); flip per-image with `sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config.d/00-alloy.conf` |

Login: `user` / `147147` (console + SSH). Root: **key-auth only** (this Mac's
key is provisioned in every Core-derived artifact; the GUI-0000 image has
password-only until you provision).

## 2. Safety patterns

**Throwaway experiment** (destructive sandbox, floor stays pristine):

```sh
qemu-img create -f qcow2 -F qcow2 -b baselines/0007/alloy-baseline-0007.qcow2 \
    baselines/0007/sandbox.qcow2
scripts/run-alloy-gui.sh baselines/0007/sandbox.qcow2     # or headless runner
# reboot inside the sandbox keeps state; delete the file to reset
```

**Checkpoint mid-experiment**: power off, `qemu-img snapshot -c <name> sandbox.qcow2`,
roll back with `qemu-img snapshot -a <name>`.

**The frozen rule**: `baselines/0007/alloy-baseline-0007.qcow2` and
`images/pmos-qemu-aarch64.qcow2` carry the macOS immutable flag (`uchg`) —
booting them directly fails at open() by design. Everything derives via
overlay. Deliberate unfreeze: `chflags nouchg <file>` (and re-freeze after).

**Verify a hash**: `shasum -a 256 -c baselines/0007/FROZEN.sha256` (and
`FROZEN-GUI0000.sha256` for the ancestor).

## 3. Changing the system safely

1. Always in an overlay of the artifact you're changing.
2. After any change, run the gates:
   ```sh
   alloy/regression-test.sh <img> core      # functional integrity
   alloy/quiescence-test.sh <img> core      # idle behavior (2-4 min)
   ```
   Both boot on their own throwaway overlay, so frozen inputs are fine.
3. **Adding packages**: plain `apk add` (network + keyring are fine). Watch
   for reverse-dependency surprises: use `apk del --simulate` before removing
   anything; remember the blocked list (`docs/ALLOY-BASELINE-0002.md` §4).
4. **Never on any ALLOY image**: `apk upgrade` bare (edge moves; snapshot
   first if you must — see §4), `swapoff -a` (kills pmOS zram until its unit
   restarts, re-arming as the next free zram device), `udevadm trigger
   --action=change` on input subsystems (empties the udev db, no self-heal),
   `rm -rf` on mountpoints.
5. Config changes go in `*.conf.d/` drop-ins named `NN-alloy.conf` (or
   `NN-prod.conf` etc.), never by editing vendor files — that keeps
   `sshd -T`-style verification and reverts trivial.

## 4. Upgrades (edge is a moving target)

The floor pins *behavior*, not versions. To upgrade:

1. Overlay the artifact; inside, snapshot-friendly: `apk upgrade` (accept
   that new versions may change behavior — the gates are the referee).
2. After a kernel upgrade: `apk fix linux-postmarketos-stable` restores any
   pruned module files; re-run `depmod -a`; re-run the module prune
   (`alloy/steps/06-modprune.sh`) if you want the footprint back.
3. Re-run both gates; if PASS, `fstrim -v / && fstrim -v /boot`, power off,
   convert to a new artifact with a new number. Never in-place on a frozen
   parent.

## 5. Making a new profile

```sh
# 1. write the delta script
$EDITOR alloy/profiles/myprofile.sh
# 2. build + gate (boot, apply, trim, flatten, regression, quiescence)
alloy/build-profile.sh myprofile
```

Thresholds live at the top of `alloy/quiescence-test.sh` (add a case for the
new profile). Regression's profile extras: add a `case` branch.

## 6. Rebuilding the Core from scratch

```sh
alloy/build-core.sh
# pristine → 8 stages (00 keys/bootstrap … 07 configs), one convert per stage,
# compressed output, both gates at the end
# prerequisites: QEMU + HVF, ~/.ssh/id_ed25519(.pub), ~20 min wall time
```

Known property: the rebuild lands at ~604 MiB (compressed) vs the frozen
0007's 698 MiB (uncompressed, carries ESP residue) — same gates, same
behavior; content-equal modulo the packaging. To unfreeze 0007 in place you
would `chflags nouchg` first; prefer deriving instead.

## 7. Troubleshooting index

| Symptom | Cause | Fix |
|---|---|---|
| Boot lands in "postmarketOS debug shell" | initramfs failure before switch_root | read `/pmOS_init.log` in the shell; `pmos_continue_boot` to retry; known causes: partition labels, fstab placeholder, force-resize |
| SSH connection refused | VM still booting (~10 s warm), or QEMU dead | `pgrep -fl qemu-system`, `nc -z localhost 2222`, `tail /tmp/serial.log` |
| getty `203/EXEC` | agetty missing (was the 0001 regression) | `apk add agetty` |
| `systemctl --failed` non-empty | anything but known-noise | `systemctl status <unit>`; `usb-signaller` is pre-masked |
| udev input tags missing | measurement raced udev, or db emptied by a change-trigger | check `udevadm info --export-db`; reboot recovers; never change-trigger input |
| SSH feels slow / harness checks fail randomly | sshd connection throttling from serial connections | multiplex (`ControlMaster`) — the gates already do |
| Image won't boot after experiment | brick | you were in a sandbox; recreate overlay. On a real artifact: restore parent via overlay chain |
| `qemu-img convert` "Failed to get write lock" | target is the source's own backing | convert to temp file, then `mv` |
| VM clock wrong / TLS errors | timesyncd hasn't converged yet post-boot | wait a minute; `systemctl restart systemd-timesyncd` |
| Disk full in guest | root fs is 3.5 G with 2 G swapfile | `df -h /`; clean `/var/cache/apk/*`; or enlarge per lab README §11 |

## 8. Measurement recipes

- **Boot time**: `baselines/0001/measure-boot.sh <img> <serial> <timings> 2222 <vars.fd>`
  (idle the host ≥30 s first; report median-of-3).
- **Idle wakeups**: `baselines/0001/collect-metrics.sh <prefix> 60` (runs the
  60 s `/proc/interrupts` window; call ≥2 min after boot).
- **Per-process attribution**: `baselines/0003/guest-profile2.sh` over SSH,
  join host-side (see `docs/ALLOY-PROFILE-0004-RUNTIME.md`).
- **The gates are also the regression suite** — run them after every change;
  they are the definition of "still works".

## 9. File map

```
baselines/000{1..7}/          measured history: artifacts, logs, evidence
alloy/core/alloy-core.qcow2   rebuilt Core (604 MiB, compressed, gated)
alloy/profiles/               dev / prod / lab artifacts
alloy/steps/                  the 8-stage deterministic recipe
alloy/keys/                   apk trust ring (self-contained builds)
alloy/build/                  scratch (logs survive, overlays don't)
docs/ALLOY-*.md               every record, packet, lineage, history, ops
```

## 10. SSH host-key pinning (SECURITY_AUDIT2)

`alloy/known_hosts` pins the guest host keys for `[127.0.0.1]:2222`; all
harnesses run `StrictHostKeyChecking=yes` against it. Fingerprints are
recorded in the file header. **Re-pinning ceremony** (new image lineage with
regenerated host keys — it will hard-fail closed until re-pinned):

1. Boot the new image, then `ssh-keyscan -p 2222 -T 10 127.0.0.1 > /tmp/ks.raw`
2. Review: `ssh-keygen -l -f /tmp/ks.raw`
3. Replace the entries for `[127.0.0.1]:2222` atomically (never blind-append)
4. Commit with a note

Never blind-keyscan over a failed verification — a mismatch is either a
regenerated guest key (expected after re-imaging) or something worth
stopping for.
