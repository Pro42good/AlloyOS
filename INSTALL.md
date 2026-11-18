# Build and use Alloy OS

[Back to the README](README.md)

Use this guide to build and boot the headless Alloy Core in QEMU. Duranium has a
separate test fixture on its development branch. The desktop and physical-device
installer are still on the roadmap.

From a checkout containing this guide, run:

```sh
./scripts/setup.sh --help
```

| Command | What it does |
| --- | --- |
| `core-build BASE.qcow2 [OUT.qcow2]` | Apply the Core recipe to a bootable postmarketOS base and run the regression and idle checks. |
| `core-run [CORE.qcow2]` | Boot Core in a disposable VM with a serial console. |
| `duranium-test` | Run unit tests, build the A/B fixture, and run the QEMU scenarios. |
| `duranium-shell` | Boot a disposable copy of the fixture and open its guest shell. |

The setup script calls the existing tools. Each command below runs from the
repository root. The earlier `scripts/install.sh` is a live postmarketOS
conversion experiment, separate from these image workflows.

## Build Alloy Core

### Prerequisites

- Apple Silicon macOS with aarch64 QEMU, `qemu-img`, and Homebrew's EDK2 firmware
  at `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`. The current Core runners use
  Apple's HVF accelerator.
- Python 3, Expect, OpenSSH tools, and a working Ed25519 key pair with its public
  key at `~/.ssh/id_ed25519.pub`. The builder provisions that public key into
  the guest and verifies the image over SSH.
- A bootable **postmarketOS `qemu-aarch64` qcow2**, with SSH and a `user` account
  that can run `sudo`. VM images are kept outside Git. Start with an existing
  base or follow the lab's rebuild instructions to produce one.
  [Base-image build instructions](devices/kukui-krane/docs/ALLOY-REPRODUCIBILITY.md#phase-1--base-image-upstream--bootable-qcow2)
- Loopback ports 2222 and 4445 available for the build and its checks.

The builder applies the recipe in overlays, stages each artifact, and checks
the final image. Shell scripts make up the current Core build tooling, so
building Core here means assembling a VM image from the supplied base.

For a **console** base such as the documented 1000 baseline:

```sh
export PMOS_PASS='replace-with-the-VM-user-password'
BASE=console ./scripts/setup.sh core-build /path/to/alloy-1000-base.qcow2
unset PMOS_PASS
```

For a **Phosh** base from the original graphical lab, use `BASE=phosh` or omit
`BASE`. The default output is
`devices/kukui-krane/alloy/core/alloy-core.qcow2`. To put it elsewhere, pass a
second path. If you already have an EDK2 variable store for the image, set
`VARS` to its path. The builder works on a copy. Otherwise it can start with a
blank store.

The builder prints the gate results and stores stage logs under
`devices/kukui-krane/alloy/build/logs/`. If a gate fails, keep its output when
reporting the problem. Core builds record the guest's SSH host keys in the
lab's `alloy/known_hosts` file. The stage logs and recipe are described in the
[Core build guide](devices/kukui-krane/alloy/README.md).

## Boot and inspect Core

```sh
./scripts/setup.sh core-run
# Or boot an existing Core image:
./scripts/setup.sh core-run /path/to/alloy-1001-floor.qcow2
```

Log in through the serial console with the guest credentials. From inside Core:

```sh
systemctl --failed
systemctl list-units --type=service --state=running
free -m
cat /proc/swaps
```

Guest disk changes go into a temporary overlay. Shut down from the guest
with `sudo poweroff`, or exit QEMU with **Ctrl+A, then X**. QEMU forwards SSH
to localhost port 2222 by default. Set `PMOS_SSH_PORT=off` for serial-only
access, or choose another port if 2222 is busy.

## Test and use Duranium

These commands require a Duranium development checkout that contains
`pkgs/duranium/`. Use the Core commands above from `main`.

Duranium uses its own small UEFI fixture. Have an operational Docker engine
with `linux/arm64` support, aarch64 QEMU, and aarch64 EDK2 firmware. Set
`DURANIUM_EDK2_CODE` if your firmware isn't in the runner's default search
paths. The Linux runner selects KVM when available and falls back to QEMU
emulation.

The builder uses `devices/kukui-krane/baselines/1000/alloy-1001-floor.qcow2` by
default to get the guest kernel and systemd-boot binary. Set
`DURANIUM_BASELINE` to another directory containing that file, or supply
`DURANIUM_KERNEL` and `DURANIUM_EFI_BOOT` as absolute paths to those two files.

```sh
./scripts/setup.sh duranium-test
./scripts/setup.sh duranium-shell
```

`duranium-test` runs the unit suite and rebuilds the fixture before running the
integration scenarios. QEMU logs go under `pkgs/duranium/qemu/out/runs/`.
`duranium-shell` reuses the built fixture or builds one on first use. Each shell
session boots a temporary disk copy.

At the guest prompt, try:

```sh
duranium status
duranium slot show A
duranium health report
duranium state schema
poweroff -f
```

Use the Duranium package guide for signed updates, metadata, and the recovery
commands. It also documents the fixture and development test suite.
See `pkgs/duranium/README.md` in the Duranium checkout.
