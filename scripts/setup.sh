#!/bin/sh
# Build and run the Alloy development VMs without installing on the host.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lab="$repo/devices/kukui-krane"
core="$lab/alloy"
duranium="$repo/pkgs/duranium"
core_image="$core/core/alloy-core.qcow2"
fixture="$duranium/qemu/out/duranium-fixture.img"

usage() {
    cat <<'EOF'
Usage: scripts/setup.sh <command>

  core-build BASE.qcow2 [OUT.qcow2]  Build Alloy Core and run both gates.
                                     Set BASE=console for a console/Nura base.
  core-run [CORE.qcow2]              Boot Core in a disposable serial VM.
  duranium-test                    Run tests in a Duranium development checkout.
  duranium-shell                   Open the fixture shell in a Duranium checkout.
  help                             Show this message.

See INSTALL.md for prerequisites and examples.
EOF
}

fail() {
    printf 'setup: %s\n' "$*" >&2
    exit 2
}

need() {
    for tool do
        command -v "$tool" >/dev/null 2>&1 || fail "missing $tool. See INSTALL.md."
    done
}

need_file() {
    [ -f "$1" ] && [ -r "$1" ] || fail "cannot read $1"
}

need_core_host() {
    [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] ||
        fail "the Core VM scripts currently use Apple Silicon macOS and HVF"
    need qemu-system-aarch64 qemu-img
    need_file /opt/homebrew/share/qemu/edk2-aarch64-code.fd
}

need_docker() {
    need docker
    docker info >/dev/null 2>&1 || fail "Docker is unavailable. Start your Docker engine and check docker info."
}

need_duranium_vm() {
    [ -x "$duranium/qemu/run-vm.sh" ] || fail "this checkout does not contain the Duranium package"
    need "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}"
    if [ -n "${DURANIUM_EDK2_CODE:-}" ]; then
        need_file "$DURANIUM_EDK2_CODE"
    elif [ ! -r /opt/homebrew/share/qemu/edk2-aarch64-code.fd ] &&
         [ ! -r /usr/share/qemu/edk2-aarch64-code.fd ] &&
         [ ! -r /usr/share/AAVMF/AAVMF_CODE.fd ]; then
        fail "set DURANIUM_EDK2_CODE to your aarch64 EDK2 firmware"
    fi
}

need_fixture_inputs() {
    if [ -n "${DURANIUM_KERNEL:-}" ]; then need_file "$DURANIUM_KERNEL"; fi
    if [ -n "${DURANIUM_EFI_BOOT:-}" ]; then need_file "$DURANIUM_EFI_BOOT"; fi
    if [ -z "${DURANIUM_KERNEL:-}" ] || [ -z "${DURANIUM_EFI_BOOT:-}" ]; then
        baseline_dir=${DURANIUM_BASELINE:-$lab/baselines/1000}
        [ -r "$baseline_dir/alloy-1001-floor.qcow2" ] ||
            fail "supply alloy-1001-floor.qcow2 via DURANIUM_BASELINE or set both DURANIUM_KERNEL and DURANIUM_EFI_BOOT"
    fi
}

scratch_dir() {
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/alloy-vm.XXXXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

action=${1:-help}
if [ "$#" -gt 0 ]; then shift; fi
case "$action" in
    help|-h|--help) usage ;;
    core-build)
        [ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail "use core-build BASE.qcow2 [OUT.qcow2]"
        need_file "$1"
        need_core_host
        need expect python3 ssh ssh-keyscan ssh-keygen scp
        need_file "$HOME/.ssh/id_ed25519.pub"
        [ -n "${PMOS_PASS:-}" ] || fail "set PMOS_PASS to the base image's user password"
        case "${BASE:-phosh}" in phosh|console) ;; *) fail "BASE must be phosh or console" ;; esac
        if [ -n "${VARS:-}" ]; then need_file "$VARS"; fi
        source_image="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
        output_image=${2:-$core_image}
        [ ! -e "$output_image" ] && [ ! -L "$output_image" ] ||
            fail "output already exists: $output_image"
        exec "$core/build-core.sh" "$source_image" "$output_image"
        ;;
    core-run)
        [ "$#" -le 1 ] || fail "use core-run [CORE.qcow2]"
        image=${1:-$core_image}
        need_file "$image"
        need_core_host
        scratch_dir
        image="$(cd "$(dirname "$image")" && pwd)/$(basename "$image")"
        qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$scratch/core.qcow2"
        if [ -n "${VARS:-}" ]; then
            need_file "$VARS"
            cp "$VARS" "$scratch/vars.fd"
        fi
        PMOS_IMG="$scratch/core.qcow2" PMOS_VARS="$scratch/vars.fd" "$lab/scripts/run-pmos-vm.sh" serial
        ;;
    duranium-test)
        [ "$#" -eq 0 ] || fail "use duranium-test without arguments"
        need_duranium_vm
        need_fixture_inputs
        need_docker
        "$duranium/tests/run-unit.sh"
        exec "$duranium/tests/qemu/run-suite.sh" --rebuild
        ;;
    duranium-shell)
        [ "$#" -eq 0 ] || fail "use duranium-shell without arguments"
        need_duranium_vm
        if [ ! -r "$fixture" ]; then
            need_fixture_inputs
            need_docker
            "$duranium/qemu/build-fixture.sh"
        fi
        scratch_dir
        if ! cp -c "$fixture" "$scratch/duranium.img" 2>/dev/null; then
            cp "$fixture" "$scratch/duranium.img"
        fi
        "$duranium/qemu/run-vm.sh" --interactive --disk "$scratch/duranium.img" --vars "$scratch/vars.fd"
        ;;
    *) usage >&2; fail "unknown command: $action" ;;
esac
