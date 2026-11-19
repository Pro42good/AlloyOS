#!/bin/sh
# Unit-test helpers for the Duranium shell implementation.

set -u

UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$UNIT_DIR/../.." && pwd)
DURANIUM_BIN="$REPO/src/bin/duranium"
DURANIUM_TEST_REPO="$REPO"
: "${DURANIUM_TEST_TMP:?DURANIUM_TEST_TMP must be set by the runner}"
KEY_ID=${KEY_ID:-test-key}

_FAILS=0
_CHECKS=0

dk() {
    "$DURANIUM_BIN" "$@"
}

# Run the CLI with temporary environment assignments. This is needed because
# POSIX variable assignments before a shell function call are not reliably
# exported into the commands the function invokes.
dk_env() {
    _envs=$1
    shift
    sh -c 'for _kv in '"$_envs"'; do export "$_kv"; done; exec "$DURANIUM_BIN" "$@"' sh "$@"
}

export DURANIUM_BIN DURANIUM_TEST_REPO

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    _FAILS=$((_FAILS + 1))
}

ok() {
    _CHECKS=$((_CHECKS + 1))
}

assert_eq() {
    _desc=$1; _want=$2; _got=$3
    if [ "$_want" = "$_got" ]; then
        ok
    else
        fail "$_desc (want '$_want', got '$_got')"
    fi
}

assert_ok() {
    _desc=$1
    shift
    if "$@" >/dev/null 2>"$DURANIUM_TEST_TMP/last.err"; then
        ok
    else
        fail "$_desc (command failed: $*)"
        sed 's/^/  /' "$DURANIUM_TEST_TMP/last.err" >&2 || true
    fi
}

assert_fail() {
    _desc=$1
    shift
    if "$@" >/dev/null 2>"$DURANIUM_TEST_TMP/last.err"; then
        fail "$_desc (command unexpectedly succeeded: $*)"
    else
        ok
    fi
}

assert_file() {
    _desc=$1; _path=$2
    if [ -f "$_path" ]; then ok; else fail "$_desc (missing file $_path)"; fi
}

assert_no_file() {
    _desc=$1; _path=$2
    if [ -e "$_path" ]; then fail "$_desc (unexpected file $_path)"; else ok; fi
}

assert_contains() {
    _desc=$1; _file=$2; _text=$3
    if [ -r "$_file" ] && grep -q -- "$_text" "$_file"; then
        ok
    else
        fail "$_desc (missing '$_text' in $_file)"
    fi
}

assert_not_contains() {
    _desc=$1; _file=$2; _text=$3
    if [ -r "$_file" ] && grep -q -- "$_text" "$_file"; then
        fail "$_desc (unexpected '$_text' in $_file)"
    else
        ok
    fi
}

assert_slot_status() {
    _desc=$1; _slot=$2; _want=$3
    _out=$("$DURANIUM_BIN" slot show "$_slot" 2>/dev/null || true)
    case "$_out" in
        *"status=$_want "*) ok ;;
        *) fail "$_desc (slot $_slot not $_want: $_out)" ;;
    esac
}

assert_slot_field() {
    _desc=$1; _slot=$2; _field=$3; _want=$4
    _out=$("$DURANIUM_BIN" slot show "$_slot" 2>/dev/null || true)
    case "$_out" in
        *"$_field=$_want"*) ok ;;
        *) fail "$_desc (slot $_slot $_field != $_want: $_out)" ;;
    esac
}

test_init() {
    TEST_NAME=$1
    T="$DURANIUM_TEST_TMP/$TEST_NAME"
    rm -rf "$T"
    mkdir -p "$T/root/boot/loader/entries" "$T/root/boot/duranium/slots" \
        "$T/root/boot/duranium/boot/A" "$T/root/boot/duranium/boot/B" \
        "$T/root/slots" "$T/root/state" "$T/root/recovery" \
        "$T/run" "$T/run/alloy" "$T/tmp" "$T/keys" "$T/migrations" \
        "$T/root/state/home" "$T/root/state/var/lib/alloy" "$T/root/state/etc/alloy" \
        "$T/root/state/var/cache" "$T/root/state/var/log" "$T/root/state/duranium/backups"
    printf '1\n' > "$T/root/state/duranium/schema"
    cp "$REPO/src/etc/state.conf" "$T/state.conf"
    dd if=/dev/zero of="$T/root/slots/A.img" bs=1M count=4 status=none
    dd if=/dev/zero of="$T/root/slots/B.img" bs=1M count=4 status=none
    touch "$T/run/alloy/core-ready"

    export DURANIUM_CONFIG="$T/duranium.conf"
    export DURANIUM_LIBDIR="$REPO/src/lib"
    export DURANIUM_BACKEND=dir
    export DURANIUM_BOOTLOADER=fake
    export DURANIUM_ROOT="$T/root"
    export DURANIUM_BOOT_MNT="$T/root/boot"
    export DURANIUM_STATE_MNT="$T/root/state"
    export DURANIUM_RECOVERY_MNT="$T/root/recovery"
    export DURANIUM_NEWROOT="$T/root"
    export DURANIUM_RUN="$T/run"
    export DURANIUM_TMP="$T/tmp"
    export DURANIUM_KEYS_DIR="$T/keys"
    export DURANIUM_STATE_CONF="$T/state.conf"
    export DURANIUM_MIGRATIONS_DIR="$T/migrations"
    export DURANIUM_SLOT_A_DEV="$T/root/slots/A.img"
    export DURANIUM_SLOT_B_DEV="$T/root/slots/B.img"
    export DURANIUM_STATE_DEV="$T/root/state"
    export DURANIUM_RECOVERY_DEV="$T/root/recovery"
    export DURANIUM_BOOT_DEV=""
    export DURANIUM_PROFILE=dev
    export DURANIUM_DEV_OVERRIDE=1
    export DURANIUM_ARCH=aarch64
    export DURANIUM_HARDWARE_TARGET=qemu-aarch64-virt
    export DURANIUM_STATE_SCHEMA=1
    export DURANIUM_TEST_MODE=1
    export DURANIUM_FSCK=0

    # Deterministic health tests on hosts with real systemd: the CLI's
    # systemctl fallback would consult the HOST's systemd state. Stub it so
    # the marker check is the only signal (matches the fixture, which has
    # no systemd).
    mkdir -p "$T/bin"
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/systemctl"
    chmod +x "$T/bin/systemctl"
    export PATH="$T/bin:$PATH"
    export DURANIUM_VERIFY_ROOT_ON_BOOT=0
    export DURANIUM_HEALTH_CORE_MARKER="$T/run/alloy/core-ready"
    export DURANIUM_HEALTH_REQUIRE_ROOT_RO=0
    export DURANIUM_HEALTH_REQUIRE_STATE=0
    export DURANIUM_HEALTH_REQUIRE_CORE=1
    export DURANIUM_MAX_BOOT_ATTEMPTS=3
    export DURANIUM_CONSOLE=console=ttyAMA0
    export DURANIUM_EXTRA_CMDLINE=""
    export DURANIUM_RECOVERY=0
    unset DURANIUM_TEST_PARTIAL_WRITE_BYTES DURANIUM_TEST_POWER_LOSS DURANIUM_TEST_FAIL_AT 2>/dev/null || true

    cat > "$DURANIUM_CONFIG" <<EOF
: "\${DURANIUM_BACKEND:=dir}"
: "\${DURANIUM_BOOT_MNT:=$T/root/boot}"
: "\${DURANIUM_STATE_MNT:=$T/root/state}"
: "\${DURANIUM_RUN:=$T/run}"
: "\${DURANIUM_STATE_CONF:=$T/state.conf}"
: "\${DURANIUM_KEYS_DIR:=$T/keys}"
: "\${DURANIUM_MIGRATIONS_DIR:=$T/migrations}"
: "\${DURANIUM_MAX_BOOT_ATTEMPTS:=3}"
: "\${DURANIUM_TEST_MODE:=1}"
EOF

    make_boot_files A "$T/bootA"
    _kh=$(sha256sum "$T/bootA/kernel" | awk '{print $1}')
    _ih=$(sha256sum "$T/bootA/initramfs" | awk '{print $1}')
    _ah=$(sha256sum "$T/root/slots/A.img" | awk '{print $1}')
    "$DURANIUM_BIN" admin init-slot A \
        alloy_version=1.0 build_id=A-v1 image_sha256="$_ah" \
        boot_kernel_sha256="$_kh" boot_initramfs_sha256="$_ih" \
        profile=dev architecture=aarch64 hardware_target=qemu-aarch64-virt \
        state_schema=1 status=GOOD known_good=1 boot_attempts_remaining=0 >/dev/null
    "$DURANIUM_BIN" admin init-slot B \
        alloy_version=unknown build_id=unknown profile=dev architecture=aarch64 \
        hardware_target=qemu-aarch64-virt state_schema=1 status=UNKNOWN known_good=0 >/dev/null
    "$DURANIUM_BIN" admin init-global active_slot=A pending_slot="" fallback_slot=A \
        last_known_good_slot=A update_in_progress="" >/dev/null
    "$DURANIUM_BIN" admin sync >/dev/null
}

make_boot_files() {
    _slot=$1
    _dir=$2
    mkdir -p "$_dir"
    printf 'kernel-%s\n' "$_slot" > "$_dir/kernel"
    printf 'initramfs-%s\n' "$_slot" > "$_dir/initramfs"
}

make_slot_good() {
    _slot=$1
    _version=$2
    _build=$3
    _dir="$T/boot$_slot"
    make_boot_files "$_slot" "$_dir"
    _kh=$(sha256sum "$_dir/kernel" | awk '{print $1}')
    _ih=$(sha256sum "$_dir/initramfs" | awk '{print $1}')
    _ah=$(sha256sum "$T/root/slots/$_slot.img" | awk '{print $1}')
    "$DURANIUM_BIN" admin init-slot "$_slot" \
        alloy_version="$_version" build_id="$_build" image_sha256="$_ah" \
        boot_kernel_sha256="$_kh" boot_initramfs_sha256="$_ih" \
        profile=dev architecture=aarch64 hardware_target=qemu-aarch64-virt \
        state_schema=1 status=GOOD known_good=1 boot_attempts_remaining=0 >/dev/null
}

set_global() {
    _active=${1:-}
    _pending=${2:-}
    _fallback=${3:-}
    _last=${4:-}
    "$DURANIUM_BIN" admin init-global active_slot="$_active" pending_slot="$_pending" \
        fallback_slot="$_fallback" last_known_good_slot="$_last" update_in_progress="" >/dev/null
}

make_slot_pending() {
    _slot=$1
    _version=$2
    _build=$3
    _schema=${4:-1}
    _active=${5:-A}
    _dir="$T/boot$_slot"
    make_boot_files "$_slot" "$_dir"
    _kh=$(sha256sum "$_dir/kernel" | awk '{print $1}')
    _ih=$(sha256sum "$_dir/initramfs" | awk '{print $1}')
    _ah=$(sha256sum "$T/root/slots/$_slot.img" | awk '{print $1}')
    "$DURANIUM_BIN" admin init-slot "$_slot" \
        alloy_version="$_version" build_id="$_build" image_sha256="$_ah" \
        boot_kernel_sha256="$_kh" boot_initramfs_sha256="$_ih" \
        profile=dev architecture=aarch64 hardware_target=qemu-aarch64-virt \
        state_schema="$_schema" status=PENDING known_good=0 \
        boot_attempts_remaining=3 max_boot_attempts=3 >/dev/null
    set_global "$_active" "$_slot" "$_active" "$_active"
    "$DURANIUM_BIN" admin sync >/dev/null
}


make_artifact() {    # make_artifact <dir> <version> <build> [profile] [arch] [hardware] [schema]
    _dir=$1
    _ver=$2
    _build=$3
    _profile=${4:-dev}
    _arch=${5:-aarch64}
    _hw=${6:-qemu-aarch64-virt}
    _schema=${7:-1}
    rm -rf "$_dir"
    mkdir -p "$_dir/boot"
    dd if=/dev/zero of="$_dir/system.img" bs=1M count=1 status=none
    printf '%s\n' "$_build" | dd of="$_dir/system.img" conv=notrunc status=none
    printf 'kernel-%s\n' "$_build" > "$_dir/boot/vmlinuz"
    printf 'initramfs-%s\n' "$_build" > "$_dir/boot/initramfs"
    _size=$(wc -c < "$_dir/system.img" | tr -d ' ')
    _sh=$(sha256sum "$_dir/system.img" | awk '{print $1}')
    _kh=$(sha256sum "$_dir/boot/vmlinuz" | awk '{print $1}')
    _ih=$(sha256sum "$_dir/boot/initramfs" | awk '{print $1}')
    cat > "$_dir/manifest.txt" <<EOF
duranium_manifest=1
format_version=1
alloy_version=$_ver
build_id=$_build
architecture=$_arch
profile=$_profile
hardware_target=$_hw
system_image=system.img
system_image_size=$_size
system_image_sha256=$_sh
system_image_compression=none
boot_kernel=boot/vmlinuz
boot_kernel_sha256=$_kh
boot_initramfs=boot/initramfs
boot_initramfs_sha256=$_ih
state_schema_required=$_schema
state_schema_backward_compatible=1
rollback_compatible=1
key_id=$KEY_ID
created_at=2026-11-17T00:00:00Z
EOF
    "$DURANIUM_BIN" manifest sign "$_dir" "$T/keys/$KEY_ID.priv.pem" >/dev/null
}

make_key() {
    "$DURANIUM_BIN" manifest keygen "$T/keys" "$KEY_ID" >/dev/null
    "$DURANIUM_BIN" manifest install-key "$T/keys/$KEY_ID.pub.pem" "$KEY_ID" >/dev/null
}

fake_boot() {
    "$DURANIUM_BIN" bootloader fake-boot
}

sim_boot() {
    _s=$(fake_boot) || return 1
    "$DURANIUM_BIN" boot-record "$_s" >/dev/null || return 1
    printf '%s\n' "$_s"
}

test_done() {
    if [ "$_FAILS" -ne 0 ]; then
        printf 'RESULT: FAIL (%s failures, %s checks)\n' "$_FAILS" "$_CHECKS" >&2
        exit 1
    fi
    printf 'RESULT: PASS (%s checks)\n' "$_CHECKS"
    exit 0
}
