# ALLOY — how we got here, and what it cost

The honest history of the Kukui-Krane ARM lab and the ALLOY stripping
program: the arc, the decision points, the alternatives that were rejected,
and a complete ledger of everything that was sacrificed to reach a 604–698
MiB headless floor at 7–8 IRQ/s idle. Companion to `ALLOY-PACKET-0000-to-
0007.md` (procedure + numbers) and `alloy/README.md` (the build program).

---

## 1. The arc (one paragraph)

The goal was never "a small VM". The goal was **Krane** — the Lenovo IdeaPad
Duet Chromebook (MT8183, Mali-G72/Panfrost, QCA6174 WiFi) — on a desk that
only has a Mac. QEMU has no MediaTek machine, so the lab keeps two tracks:
the official Krane image for the real device, and a **Krane-like QEMU
environment** (same arch, same distro, same UI stack, same workflows). The
Krane-like environment started as a full Phosh desktop image, then got
stripped — step by measured step — into the **ALLOY floor**: a headless
mutable postmarketOS core that carries exactly the substrate Krane's real OS
will need (kernel, firmware, Mesa/Panfrost, systemd, net/audio/input, SSH)
and nothing graphical. The floor is frozen; everything after it is profiles,
lineages, and gates.

## 2. Timeline

| When | What happened |
|---|---|
| Day 0 morning | Krane research verified from primary sources: mainline DT `mt8183-kukui-krane-sku176.dts`, coreboot `BOARD_GOOGLE_KRANE`, pmOS port `google-kukui` (community, maintainer WeirdTreeThing), ChromeOS EOL. `docs/KRANE_SPECS.md`, `docs/QEMU_VS_KRANE.md`. |
| Day 0 | Host proven: Apple M2 + QEMU 11.1.1 + HVF (`-accel hvf -cpu host`), Alpine-virt aarch64 ISO boots → the `virt` machine path works. Official Krane image downloaded + sha256-verified + dissected (Depthcharge kpart, MT8183 DTB family, ath10k `LE_Krane` cal). **Verdict: the Krane image can never boot in QEMU** — no MT8183 machine model. |
| Day 0 | pmbootstrap 3.11.1 in Docker (Ubuntu 24.04) → `qemu-aarch64` + **Phosh** + **systemd** on edge. Eight separate build gotchas (§5 below); the last one (`fstab` injection via `debugfs`) was the one that made it boot. Result: GUI-0000, the 2.2 GiB Phosh image. |
| Day 0 | VM verified: EDK2 → systemd-boot → pmOS initramfs stage 1+2 → systemd → greetd → Phosh; SSH on localhost:2222; `usb-signaller` masked. |
| Day 1 | **ALLOY-BASELINE-0001** — the strip: 1187 → 267 pkgs (2081 → 632 MB payload). Pre-strip reference: 183 MiB boot RAM, 130 procs, 27 services, 114.9 IRQ/s. Caught the agetty regression before shipping. |
| Day 1 | **0002** — boot-file/var cuts + the blocked-deps map (what can never be `apk del`'d and why). 754 MiB. |
| Day 1 | **0003** — hwdb diet: 13.5 MB trie → 288 KB, classification proven intact. 714 MiB. |
| Day 1 | **0004** — runtime tuning (profile-driven): sysctls, `psi=0`, THP=madvise, wpa/rtkit on D-Bus activation. 11.4 IRQ/s (−50 %). |
| Day 1 | **0005** — IRQ floor (`compaction_proactiveness=0` after the watchdog theory failed its A/B) + zram→disk swap layering with the OOM-panic boundary measured. 8.73 IRQ/s. |
| Day 1 | **0006** — kernel-module diet: 2176 → 625 files (72.8 → 23.3 MB), `depmod` + resolution proofs. 6.92 IRQ/s. |
| Day 1 | **0007** — configuration sweep: dev tunnels un-blocked, LLMNR/probes off, journal+session hygiene. 698 MiB. Frozen. |
| Day 1 | **0008 program** — CORE + GUI-0000 frozen (sha256 + immutable flag); reproducible 8-stage Core build; dev/prod/lab profiles; regression + quiescence gates; graphical lineage formalized. Rebuilt Core: **604 MiB compressed**, both gates ALL PASS. |
| Day 1 | Storage forensics: 24 GB reclaimed (colima fossils + TRIM, Krane `.img` duplicate, pmbootstrap-era leftovers). |

## 3. Decision ledger (the points where it could have gone differently)

1. **Two tracks instead of one.** Alternative: flash-analyze only the real
   device. Rejected: no device in hand; the VM preserves distro/UI/workflow
   fidelity at near-native speed. Accepted limitation: kernel/driver work
   stays off the table until real hardware.
2. **`virt` machine + virtio, not TCG-software MT8183 approximation.**
   Alternative: `-M virt` with `-cpu cortex-a72` under TCG (10–20× slower).
   Rejected: HVF `host` gives near-native; MT8183 topology (big.LITTLE) is
   not emulatable under HVF anyway.
3. **pmbootstrap in Docker with manual disk assembly.** Alternative: native
   Linux build host. Rejected: none available. Cost: eight gotchas, of which
   three were structural (loop partitions, udev events, virtiofs locking).
4. **Strip from the Phosh image rather than build a fresh minimal image.**
   Alternative: `pmbootstrap` with `postmarketos-base` only, no UI. Rejected
   at the time (the Phosh image was already built and verified); the
   reproducible Core build now does effectively that. Accepted cost: the
   floor's *provenance* includes a UI that was later removed.
5. **Overlay-per-state, frozen parents.** Alternative: keep mutating one
   image. Rejected: measurement requires reproducible before/after; frozen
   artifacts make every step revertible.
6. **Keep-list pins before deletion** (0001). Alternative: delete then notice
   what broke. The agetty incident proved the value of the other order.
7. **Upstream-only constraint** (the user's explicit rule). Cost: LLVM (168
   MB), X11 client libs, cracklib, tpm2-tss, spirv-tools all stay because
   they're hard deps of mesa/base/NM. Benefit: every config survives `apk`
   operations, nothing forks pmaports. This is the single biggest deliberate
   sacrifice in the other direction: **we kept weight to keep compatibility**.
8. **Compressed Core packaging** (`-c`): −~100 MiB vs the uncompressed
   rebuild, at the cost of write-amplification on the compressed clusters.
   Chosen because chained-overlay residue (see §5.9) made the honest
   uncompressed size fragile; per-stage flattening (now in `build-core.sh`)
   makes future uncompressed builds viable again.
9. **Gates as the definition of "works"**: regression (functional integrity)
   + quiescence (idle behavior). Alternative: eyeball it. Every artifact
   above the floor must pass both or it doesn't exist.

## 4. Sacrifice ledger — what was traded away, with the price

**Functional sacrifices on the floor:**

| Sacrificed | Price paid | Why / where it lives now |
|---|---|---|
| Phosh, greetd, plymouth, squeekboard, all GNOME-mobile apps, firefox-esr, GStreamer, flatpak | −1.4 GB, −15 services, on-device UI experimentation | UI work branches from **ALLOY-GUI-0000**, never the floor |
| In-VM browsing | none — host does it | — |
| PSI pressure telemetry (`psi=0`) | systemd/psimon pressure observability | −0.4–1 IRQ/s; oomd was already masked; re-enable + re-measure if Duranium wants pressure-based policy |
| Transparent hugepages (`madvise`) | THP perf for future THP-hungry apps | −2 IRQ/s of compaction churn |
| Proactive compaction | slower recovery under fragmentation | only matters under memory pressure; the 0005 demo showed flat latency anyway |
| chrony | advanced time-sync (kernel discipline, RTC drift handling) | systemd-timesyncd is the time source; adequate for TLS/dev |
| LLMNR + mDNS | `.local` name discovery | headless dev doesn't need it; sockets closed |
| NM connectivity check | captive-portal detection | headless NAT VM |
| bluetooth.service (disabled, bluez kept) | accidental BT activation | Krane profile re-enables |
| Persistent journal ≥10 MB (and *all* persistence in prod) | deep log history; **post-crash logs in prod** | volatility is the mobile-embedded norm; prod accepts it for eMMC wear |
| `modprobe`-able non-virtio hardware (e1000, WiFi, BT-USB) | attach-and-go for exotic QEMU devices | `apk fix linux-postmarketos-stable` restores; floor is pinned to the documented runner |
| `apk audit` cleanliness | package-integrity verification is dirty (module/hwdb/boot-file cuts) | the price of file-level stripping without forking; parents are the rollback path |
| System.map + dtbs on the ESP | kernel symbol debugging from /boot; multi-device DTB fleet | Krane kernel work needs the Krane kernel package anyway |
| hwdb vendor name lookups | `ID_MODEL_FROM_DATABASE` cosmetics | functional quirks (60-/61-/70-*) all kept |
| Root SSH password login | password convenience | key-only is the point; console login keeps the password |
| In-floor dev tools (git, gcc, python3, editors) | "just compile something" | that's what **dev/lab profiles** are for; the floor stays minimal |

**Sacrifices in the other direction (kept to stay upstream / Krane-true):**

| Kept despite weight | Why |
|---|---|
| LLVM 168 MB (inside mesa stack) | llvmpipe + the DRI shims link it; removing needs a pmaports rebuild (queued as structural track) |
| X11 client libs, xkeyboard-config | hard deps of mesa/pipewire/alsa/base |
| cracklib + libpwquality, tpm2-tss, spirv-tools, nss | hard deps of base/NM/bluez chains |
| NetworkManager (vs lighter networkd) | Krane parity; 14 MB RSS is the price of identical behavior |
| wpa_supplicant + bluez + rtkit | Krane WiFi/BT/audio essentials, D-Bus-activated (zero idle cost) |
| hkdm, routewrangler, apk-inhibit | tiny pmOS mobile plumbing (hotkeys, routing policy, suspend-safety) |
| getty@tty1 + serial-getty | console login + the serial debug path are keep-list items |
| 5.5 s EDK2 firmware stage | UEFI boot is the qemu-native path; direct-kernel boot exists as a lab-only, non-comparable mode |

**Process sacrifices (honest accounting):**

- Three measurement methodologies were burned and replaced mid-program
  (single timed boot → median-of-3 on an idle host; in-window collectors
  delayed ≥2 min; harnesses multiplexed SSH after self-throttling).
- One artifact-fix was clobbered by its own rebuild pipeline (0001 agetty);
  the "know which file your VM writes" rule exists because of it.
- The first Core rebuild shipped with residue (1506 MiB) because chained
  overlays read deleted LBAs through to the source; per-stage flattening
  fixed the *script*, and the compressed artifact ships clean.

## 5. The gotcha graveyard (each one cost real time)

1. Docker cannot expose loop partitions → manual disk assembly (`fixup`).
2. virtiofs locking corrupts `passwd` → pmbootstrap work dir must live
   container-native.
3. Fresh pmbootstrap rootfs ships a **placeholder fstab** → initramfs debug
   shell on every boot; the fix was `debugfs` fstab injection.
4. `pmos.force-partition-resize` on an un-fsck'd fs → removed from cmdline.
5. EDK2 NVRAM corruption → vars file auto-recreate.
6. Empty apk keyring in the built image → refreshed from the pmbootstrap
   chroot; later baked into `alloy/keys/`.
7. agetty is its own Alpine package now — GUI-side orphan, 203/EXEC.
8. `fstrim -v /` doesn't cover vfat — trim `/boot` too or compaction keeps
   the freed blocks.
9. APFS settling after a big convert fakes 20 s boots — idle the host first.
10. `ps | grep -c X` counts the grep.
11. PSI is kernel-default-on here — `psi=1` removal is a no-op; `psi=0` is
    the only off switch.
12. `swapoff -a` kills pmOS zram (unit-armed, not fstab) and it re-arms as
    the *next free* zram device.
13. `rm -rf <mountpoint>` deletes the dir; the next tmpfs mount fails
    silently.
14. Masked ssh stderr also masks *remote* errors.
15. Incompressible memory demand near 100 % RAM → **OOM kernel panic**
    (`panic_on_oom` semantics) — fast-fail by design.
16. `sshd -T` echoes option names in configured case — match with `-i`.
17. `udevadm info -q property <dev>` intermittently omits db tags;
    `--export-db` is reliable; and never `trigger --action=change` on input
    subsystems (empties the db, no self-heal).
18. Chained qcow2 overlays read deleted LBAs through to the source image.
19. `qemu-img convert overlay <its-own-backing>` deadlocks — temp file + mv.
20. Harnesses that make 40 sequential SSH connections throttle themselves —
    multiplex with ControlMaster.

## 6. The rules that survived contact

1. Pin before delete; verify after every step; measure before *and* after.
2. The pristine image and every parent artifact are sacred — write only in
   overlays, deliver only flattened converts.
3. Fix scripts, not just instances (every manual fix became part of
   `alloy/steps/`).
4. Failed experiments are recorded with the same care as wins — they are
   the difference between a floor and a pile.
5. Nothing forks. Every reduction is config, enablement, or file-level with
   a documented restore path.
