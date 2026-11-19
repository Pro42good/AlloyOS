#!/bin/sh
# Runs inside Alpine. Builds the Duranium QEMU fixture and test-data disk.

set -eu

SRC=${SRC:-/src}
OUT=${OUT:-/out}
BASELINE=${BASELINE:-/baseline}
PROFILE=${PROFILE:-prod}
MAX_BOOT=3

# Fixture architecture. The Duranium code is architecture-independent; only
# the kernel, the UEFI boot manager and the console differ. The default
# fixture is aarch64 (the target device architecture); an x86_64 fixture
# (native KVM on x86_64 hosts, for fast functional verification) requires
# DURANIUM_KERNEL and DURANIUM_EFI_BOOT (a systemd-bootx64.efi).
FIX_ARCH=${DURANIUM_FIXTURE_ARCH:-aarch64}
case "$FIX_ARCH" in
    aarch64)
        ARCH=aarch64
        HW=qemu-aarch64-virt
        CONSOLE=ttyAMA0
        EFI_BOOT_NAME=BOOTAA64.EFI
        SB_EFI=systemd-bootaa64.efi
        ;;
    x86_64)
        ARCH=x86_64
        HW=qemu-x86_64-pc
        CONSOLE=ttyS0
        EFI_BOOT_NAME=BOOTX64.EFI
        SB_EFI=systemd-bootx64.efi
        ;;
    *) die "unknown fixture arch: $FIX_ARCH" ;;
esac

BOOT_MB=128
RECOVERY_MB=128
SYSTEM_MB=128
STATE_MB=128
TESTDATA_MB=1536
DISK_MB=660

BOOT_OFFSET_MB=1
RECOVERY_OFFSET_MB=129
A_OFFSET_MB=257
B_OFFSET_MB=385
STATE_OFFSET_MB=513

log() { printf '==> %s\n' "$*"; }
die() { printf 'build: error: %s\n' "$*" >&2; exit 1; }
put() { _src=$1; _dst=$2; _mode=${3:-644}; mkdir -p "$(dirname "$_dst")"; cp "$_src" "$_dst"; chmod "$_mode" "$_dst"; }

[ "$(uname -m)" = "$ARCH" ] || die "fixture build must run on $ARCH (got $(uname -m))"

log "installing build tools"
apk update -q >/dev/null 2>&1
apk add -q e2fsprogs e2fsprogs-extra mtools dosfstools gptfdisk sgdisk qemu-img openssl busybox-static gzip cpio tar >/dev/null

rm -rf /tmp/dur-build
mkdir -p /tmp/dur-build /out /out/keys
W=/tmp/dur-build

# ---------------------------------------------------------------------------
# Kernel and systemd-boot
# ---------------------------------------------------------------------------
extract_from_baseline() {
    _img=$1
    [ -r "$_img" ] || return 1
    log "extracting kernel and systemd-boot from $(basename "$_img")"
    qemu-img convert -O raw "$_img" "$W/baseline.raw" >/dev/null
    dd if="$W/baseline.raw" of="$W/baseline-esp.img" bs=512 skip=2048 count=1048576 status=none
    mcopy -o -i "$W/baseline-esp.img" ::/vmlinuz "$W/vmlinuz"
    mcopy -o -i "$W/baseline-esp.img" ::/EFI/BOOT/$EFI_BOOT_NAME "$W/$SB_EFI"
}

if [ -n "${DURANIUM_KERNEL:-}" ] && [ -r "${DURANIUM_KERNEL:-}" ]; then
    cp "$DURANIUM_KERNEL" "$W/vmlinuz"
    [ -n "${DURANIUM_EFI_BOOT:-}" ] && [ -r "${DURANIUM_EFI_BOOT:-}" ] && cp "$DURANIUM_EFI_BOOT" "$W/$SB_EFI"
fi
if [ ! -s "$W/vmlinuz" ] || [ ! -s "$W/$SB_EFI" ]; then
    _base=""
    if [ -r "$BASELINE/alloy-1001-floor.qcow2" ]; then
        _base="$BASELINE/alloy-1001-floor.qcow2"
    else
        _base=$(find "$BASELINE" -maxdepth 2 -name 'alloy-1001-floor.qcow2' 2>/dev/null | head -n 1 || true)
    fi
    [ -n "$_base" ] || die "baseline alloy-1001-floor.qcow2 not found; set DURANIUM_BASELINE or DURANIUM_KERNEL/DURANIUM_EFI_BOOT"
    extract_from_baseline "$_base"
fi
[ -s "$W/vmlinuz" ] || die "kernel extraction failed"
[ -s "$W/$SB_EFI" ] || die "systemd-boot extraction failed"
log "kernel: $(wc -c < "$W/vmlinuz") bytes; systemd-boot: $(wc -c < "$W/$SB_EFI") bytes"

if [ "$ARCH" = "x86_64" ]; then
    # No x86_64 baseline exists; the kernel and boot manager must be
    # provided explicitly (e.g. the host distro kernel and Debian's
    # systemd-boot-efi package).
    [ -s "$W/vmlinuz" ] || die "x86_64 fixture requires DURANIUM_KERNEL"
    [ -s "$W/$SB_EFI" ] || die "x86_64 fixture requires DURANIUM_EFI_BOOT (systemd-bootx64.efi)"
fi

# ---------------------------------------------------------------------------
# Keys and artifacts
# ---------------------------------------------------------------------------
if [ ! -r "$OUT/keys/test-key.priv.pem" ]; then
    log "generating test signing keys"
    DURANIUM_LIBDIR="$SRC/src/lib" "$SRC/src/bin/duranium" manifest keygen "$OUT/keys" test-key
    DURANIUM_LIBDIR="$SRC/src/lib" "$SRC/src/bin/duranium" manifest keygen "$OUT/keys" wrong-key
fi
TESTKEY="$OUT/keys/test-key.priv.pem"
WRONGKEY="$OUT/keys/wrong-key.priv.pem"
TESTPUB="$OUT/keys/test-key.pub.pem"

# ---------------------------------------------------------------------------
# Base root filesystem
# ---------------------------------------------------------------------------
log "building Alpine base root filesystem"
BASE=$W/base-root
rm -rf "$BASE"
mkdir -p "$BASE/etc/apk/keys"
cp /etc/apk/keys/* "$BASE/etc/apk/keys/"
apk add --root "$BASE" --initdb --keys-dir /etc/apk/keys \
    --repositories-file /etc/apk/repositories -U alpine-base openssl e2fsprogs util-linux >/dev/null 2>&1

# Duranium itself.
put "$SRC/src/bin/duranium" "$BASE/usr/bin/duranium" 755
for _f in "$SRC"/src/lib/*.sh; do put "$_f" "$BASE/usr/lib/duranium/$(basename "$_f")" 644; done
put "$SRC/src/etc/duranium.conf" "$BASE/etc/duranium/duranium.conf" 644
# The guest reads its console default from this config; align it with the
# fixture architecture (a no-op for the default ttyAMA0).
sed -i "s/console=ttyAMA0/console=$CONSOLE/" "$BASE/etc/duranium/duranium.conf"
put "$SRC/src/etc/state.conf" "$BASE/etc/duranium/state.conf" 644
put "$SRC/src/etc/health.d/10-core.sh" "$BASE/etc/duranium/health.d/10-core.sh" 644
put "$SRC/qemu/guest-agent.sh" "$BASE/usr/local/bin/duranium-test" 755
put "$TESTPUB" "$BASE/etc/duranium/keys/test-key.pub" 644
printf 'core\n' > "$BASE/etc/duranium/core-services"
printf 'alloy-qemu\n' > "$BASE/etc/hostname"
cat > "$BASE/etc/os-release" <<'EOF'
NAME="Alloy OS (Duranium fixture)"
ID=alloy
ID_LIKE=alpine
VERSION_ID="duranium-v1"
PRETTY_NAME="Alloy OS Duranium V1 QEMU fixture"
EOF
rm -f "$BASE/sbin/init"
for _p in home var/lib/alloy etc/alloy var/cache var/log var/tmp run tmp state boot testdata proc sys dev root usr/local/bin; do
    mkdir -p "$BASE/$_p"
done
printf 'version=base\n' > "$BASE/etc/alloy-version"
printf 'version=base\n' > "$BASE/etc/alloy/settings.conf"
chmod 1777 "$BASE/home" "$BASE/tmp" "$BASE/var/tmp" 2>/dev/null || true

make_rootfs() {
    _slot=$1; _version=$2; _schema=$3; _profile=$4; _kind=$5; _migrations=$6; _out=$7; _label=$8
    _root=$W/rootfs-$_slot-$_version
    rm -rf "$_root"
    cp -a "$BASE" "$_root"
    printf '%s\n' "$_slot" > "$_root/etc/duranium/slot"
    printf '%s\n' "$_profile" > "$_root/etc/duranium/profile"
    printf '%s\n' "$HW" > "$_root/etc/duranium/hardware-target"
    printf '%s\n' "$_schema" > "$_root/etc/duranium/state-schema"
    printf 'version=%s\n' "$_version" > "$_root/etc/alloy-version"
    printf 'version=%s\n' "$_version" > "$_root/etc/alloy/settings.conf"
    rm -f "$_root/sbin/init"
    if [ "$_kind" = "recovery" ]; then
        put "$SRC/src/recovery/init" "$_root/sbin/init" 755
    else
        put "$SRC/src/root/sbin-init" "$_root/sbin/init" 755
    fi
    if [ "$_migrations" = "1" ]; then
        mkdir -p "$_root/usr/lib/duranium/migrations"
        put "$SRC/src/migrations/1-to-2.sh" "$_root/usr/lib/duranium/migrations/1-to-2.sh" 755
        put "$SRC/src/migrations/1-to-2.conf" "$_root/usr/lib/duranium/migrations/1-to-2.conf" 644
    fi
    rm -f "$_out"
    mke2fs -t ext4 -F -L "$_label" -d "$_root" "$_out" "${SYSTEM_MB}M" >/dev/null 2>&1
    log "rootfs $_label ($_slot $_version) -> $(basename "$_out")"
}

make_rootfs A A-v1 1 "$PROFILE" root 0 "$W/slot-a.img" SYSTEM_A
make_rootfs B B-v2 2 "$PROFILE" root 1 "$W/payload-b-v2.img" SYSTEM_B
make_rootfs A A-v3 2 "$PROFILE" root 1 "$W/payload-a-v3.img" SYSTEM_A
make_rootfs RECOVERY recovery 1 "$PROFILE" recovery 0 "$W/recovery.img" RECOVERY

# ---------------------------------------------------------------------------
# Initramfs (per slot and recovery)
# ---------------------------------------------------------------------------
log "building initramfs base"
IR=$W/initramfs-base
rm -rf "$IR"
mkdir -p "$IR/bin" "$IR/sbin" "$IR/usr/bin" "$IR/usr/sbin" "$IR/usr/lib/duranium" \
    "$IR/etc/duranium" "$IR/dev" "$IR/proc" "$IR/sys" "$IR/run" "$IR/mnt/boot" "$IR/sysroot" "$IR/recovery"
cp /bin/busybox.static "$IR/bin/busybox"
for _a in sh ash mount umount mkdir rmdir cat echo printf sleep sync ls cp mv rm ln chmod date \
    basename dirname tr wc awk sed grep head tail cut sort find xargs sha256sum poweroff reboot \
    switch_root true false test dd tee readlink uname; do
    ln -sf busybox "$IR/bin/$_a"
done
put "$SRC/src/bin/duranium" "$IR/usr/bin/duranium" 755
for _f in "$SRC"/src/lib/*.sh; do put "$_f" "$IR/usr/lib/duranium/$(basename "$_f")" 644; done
put "$SRC/src/initramfs/init" "$IR/init" 755
put "$SRC/src/etc/initramfs.conf" "$IR/etc/duranium/initramfs.conf" 644
sed -i "s/console=ttyAMA0/console=$CONSOLE/" "$IR/etc/duranium/initramfs.conf"
put "$SRC/src/etc/state.conf" "$IR/etc/duranium/state.conf" 644
printf '%s\n' "$PROFILE" > "$IR/etc/duranium/profile"
printf '%s\n' "$HW" > "$IR/etc/duranium/hardware-target"

make_initramfs() {
    _slot=$1; _mode=$2; _out=$3
    _dir=$W/ir-$_slot-$_mode
    rm -rf "$_dir"
    cp -a "$IR" "$_dir"
    printf '%s\n' "$_slot" > "$_dir/etc/duranium/slot"
    printf '%s\n' "$_mode" > "$_dir/etc/duranium/mode"
    ( cd "$_dir" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$_out" )
    log "initramfs $_slot ($_mode) -> $(basename "$_out")"
}
make_initramfs A normal "$W/initramfs-a"
make_initramfs B normal "$W/initramfs-b"
make_initramfs RECOVERY recovery "$W/initramfs-recovery"

# ---------------------------------------------------------------------------
# Boot staging (FAT ESP), metadata, entries
# ---------------------------------------------------------------------------
log "staging BOOT and initial metadata"
BS=$W/bootstage
rm -rf "$BS"
mkdir -p "$BS/EFI/BOOT" "$BS/loader/entries" \
    "$BS/duranium/boot/A" "$BS/duranium/boot/B" "$BS/duranium/boot/recovery" \
    "$BS/duranium/slots"
cp "$W/$SB_EFI" "$BS/EFI/BOOT/$EFI_BOOT_NAME"
for _s in A B recovery; do
    cp "$W/vmlinuz" "$BS/duranium/boot/$_s/vmlinuz"
done
cp "$W/initramfs-a" "$BS/duranium/boot/A/initramfs"
cp "$W/initramfs-b" "$BS/duranium/boot/B/initramfs"
cp "$W/initramfs-recovery" "$BS/duranium/boot/recovery/initramfs"

export DURANIUM_LIBDIR="$SRC/src/lib"
export DURANIUM_CONFIG="$W/build.conf"
export DURANIUM_BACKEND=dir
export DURANIUM_BOOT_MNT="$BS"
export DURANIUM_STATE_MNT="$W/state-root"
export DURANIUM_RUN="$W/run"
export DURANIUM_TMP="$W/tmp"
export DURANIUM_SLOT_A_DEV="$W/slot-a.img"
export DURANIUM_SLOT_B_DEV="$W/slot-b.img"
export DURANIUM_STATE_DEV="$W/state.img"
export DURANIUM_RECOVERY_DEV="$W/recovery.img"
export DURANIUM_PROFILE="$PROFILE"
export DURANIUM_HARDWARE_TARGET="$HW"
export DURANIUM_ARCH="$ARCH"
export DURANIUM_STATE_SCHEMA=1
export DURANIUM_MAX_BOOT_ATTEMPTS="$MAX_BOOT"
export DURANIUM_CONSOLE=console=$CONSOLE
export DURANIUM_EXTRA_CMDLINE=""
export DURANIUM_KEYS_DIR="$OUT/keys"
export DURANIUM_TEST_MODE=0
mkdir -p "$DURANIUM_RUN" "$DURANIUM_TMP" "$W/state-root"
cat > "$DURANIUM_CONFIG" <<EOF
: "\${DURANIUM_BACKEND:=dir}"
: "\${DURANIUM_BOOT_MNT:=$BS}"
: "\${DURANIUM_STATE_MNT:=$W/state-root}"
: "\${DURANIUM_RUN:=$W/run}"
: "\${DURANIUM_MAX_BOOT_ATTEMPTS:=$MAX_BOOT}"
EOF

A_HASH=$(sha256sum "$W/slot-a.img" | awk '{print $1}')
AK_HASH=$(sha256sum "$W/vmlinuz" | awk '{print $1}')
AI_HASH=$(sha256sum "$W/initramfs-a" | awk '{print $1}')
"$SRC/src/bin/duranium" admin init-slot A \
    alloy_version=A-v1 build_id=A-v1 image_sha256="$A_HASH" \
    boot_kernel_sha256="$AK_HASH" boot_initramfs_sha256="$AI_HASH" \
    profile="$PROFILE" architecture="$ARCH" hardware_target="$HW" \
    state_schema=1 status=GOOD known_good=1 boot_attempts_remaining=0
"$SRC/src/bin/duranium" admin init-slot B \
    alloy_version=unknown build_id=unknown profile="$PROFILE" architecture="$ARCH" \
    hardware_target="$HW" state_schema=1 status=UNKNOWN known_good=0 \
    boot_attempts_remaining=0
"$SRC/src/bin/duranium" admin init-global active_slot=A pending_slot="" fallback_slot=A \
    last_known_good_slot=A update_in_progress=""
"$SRC/src/bin/duranium" admin sync

mkfs.vfat -F32 -n DURANIUM -C "$W/boot.fat" 131072 >/dev/null
mmd -i "$W/boot.fat" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries \
    ::/duranium ::/duranium/boot ::/duranium/boot/A ::/duranium/boot/B \
    ::/duranium/boot/recovery ::/duranium/slots
mcopy -s -o -i "$W/boot.fat" "$BS"/* ::/
log "BOOT entries:"
mdir -i "$W/boot.fat" ::/loader/entries 2>/dev/null | sed -n '1,20p'

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
log "building STATE"
ST=$W/state-root
rm -rf "$ST"
mkdir -p "$ST/home/user" "$ST/etc/alloy" "$ST/var/lib/alloy" "$ST/var/cache" \
    "$ST/var/log" "$ST/duranium/backups"
printf 'seed-user\n' > "$ST/home/user/seed.txt"
printf 'seed-setting\n' > "$ST/etc/alloy/settings.conf"
printf '1\n' > "$ST/duranium/schema"
rm -f "$W/state.img"
mke2fs -t ext4 -F -L duranium-state -d "$ST" "$W/state.img" "${STATE_MB}M" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Disk assembly
# ---------------------------------------------------------------------------
log "assembling GPT disk"
rm -f "$OUT/duranium-fixture.img"
truncate -s "${DISK_MB}M" "$OUT/duranium-fixture.img"
sgdisk -a 2048 \
    -n 1:2048:+${BOOT_MB}M -t 1:ef00 -c 1:duranium-boot \
    -n 2:0:+${RECOVERY_MB}M -t 2:8300 -c 2:duranium-recovery \
    -n 3:0:+${SYSTEM_MB}M -t 3:8300 -c 3:duranium-system-a \
    -n 4:0:+${SYSTEM_MB}M -t 4:8300 -c 4:duranium-system-b \
    -n 5:0:+${STATE_MB}M -t 5:8300 -c 5:duranium-state \
    "$OUT/duranium-fixture.img" >/dev/null
dd if="$W/boot.fat" of="$OUT/duranium-fixture.img" bs=1M seek="$BOOT_OFFSET_MB" conv=notrunc status=none
dd if="$W/recovery.img" of="$OUT/duranium-fixture.img" bs=1M seek="$RECOVERY_OFFSET_MB" conv=notrunc status=none
dd if="$W/slot-a.img" of="$OUT/duranium-fixture.img" bs=1M seek="$A_OFFSET_MB" conv=notrunc status=none
# SYSTEM_B intentionally empty (UNKNOWN).
dd if="$W/state.img" of="$OUT/duranium-fixture.img" bs=1M seek="$STATE_OFFSET_MB" conv=notrunc status=none
sync
sgdisk -p "$OUT/duranium-fixture.img" | sed -n '1,20p'
cat > "$OUT/fixture.env" <<EOF
BOOT_OFFSET_MB=$BOOT_OFFSET_MB
RECOVERY_OFFSET_MB=$RECOVERY_OFFSET_MB
A_OFFSET_MB=$A_OFFSET_MB
B_OFFSET_MB=$B_OFFSET_MB
STATE_OFFSET_MB=$STATE_OFFSET_MB
DISK_MB=$DISK_MB
EOF

# ---------------------------------------------------------------------------
# Test data (artifacts + scenarios)
# ---------------------------------------------------------------------------
log "building signed update artifacts"
TD=$W/testdata-root
rm -rf "$TD"
mkdir -p "$TD/artifacts" "$TD/scenarios"
printf '.duranium-test\n' > "$TD/.duranium-test"
cp "$SRC"/tests/qemu/scenarios/*.sh "$TD/scenarios/"
printf 'acceptance\n' > "$TD/scenario"

write_manifest() {
    _dir=$1; _build=$2; _version=$3; _profile=$4; _arch=$5; _hw=$6; _schema=$7; _keyid=$8
    _size=$(wc -c < "$_dir/system.img" | tr -d ' ')
    _sh=$(sha256sum "$_dir/system.img" | awk '{print $1}')
    _kh=$(sha256sum "$_dir/boot/vmlinuz" | awk '{print $1}')
    _ih=$(sha256sum "$_dir/boot/initramfs" | awk '{print $1}')
    cat > "$_dir/manifest.txt" <<EOF
duranium_manifest=1
format_version=1
alloy_version=$_version
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
key_id=$_keyid
created_at=2026-11-17T00:00:00Z
EOF
    if [ "$_keyid" = "wrong-key" ]; then
        "$SRC/src/bin/duranium" manifest sign "$_dir" "$WRONGKEY"
    else
        "$SRC/src/bin/duranium" manifest sign "$_dir" "$TESTKEY"
    fi
}

make_artifact() {
    _dir=$1; _payload=$2; _initramfs=$3; _build=$4; _version=$5; _profile=$6; _arch=$7; _hw=$8; _schema=$9
    mkdir -p "$_dir/boot"
    cp "$_payload" "$_dir/system.img"
    cp "$W/vmlinuz" "$_dir/boot/vmlinuz"
    cp "$_initramfs" "$_dir/boot/initramfs"
    write_manifest "$_dir" "$_build" "$_version" "$_profile" "$_arch" "$_hw" "$_schema" test-key
}

make_artifact "$TD/artifacts/b-v2" "$W/payload-b-v2.img" "$W/initramfs-b" b-v2 2.0 "$PROFILE" "$ARCH" "$HW" 2
make_artifact "$TD/artifacts/a-v3" "$W/payload-a-v3.img" "$W/initramfs-a" a-v3 3.0 "$PROFILE" "$ARCH" "$HW" 2

# Variant artifacts reuse the same payload/boot files via hardlinks where
# possible. They exist to exercise rejection paths.
copy_variant() {
    _src=$1; _dst=$2
    mkdir -p "$_dst/boot"
    ln "$_src/system.img" "$_dst/system.img" 2>/dev/null || cp "$_src/system.img" "$_dst/system.img"
    ln "$_src/boot/vmlinuz" "$_dst/boot/vmlinuz" 2>/dev/null || cp "$_src/boot/vmlinuz" "$_dst/boot/vmlinuz"
    ln "$_src/boot/initramfs" "$_dst/boot/initramfs" 2>/dev/null || cp "$_src/boot/initramfs" "$_dst/boot/initramfs"
    cp "$_src/manifest.txt" "$_dst/manifest.txt"
    cp "$_src/manifest.sig" "$_dst/manifest.sig" 2>/dev/null || true
}

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/bad-manifest"
printf 'surprise=1\n' >> "$TD/artifacts/bad-manifest/manifest.txt"

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/bad-payload"
rm -f "$TD/artifacts/bad-payload/system.img"
cp "$TD/artifacts/b-v2/system.img" "$TD/artifacts/bad-payload/system.img"
printf 'tamper\n' >> "$TD/artifacts/bad-payload/system.img"

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/bad-key"
sed 's/^key_id=.*/key_id=wrong-key/' "$TD/artifacts/b-v2/manifest.txt" > "$TD/artifacts/bad-key/manifest.txt"
"$SRC/src/bin/duranium" manifest sign "$TD/artifacts/bad-key" "$WRONGKEY"

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/wrong-profile"
sed 's/^profile=.*/profile=lab/' "$TD/artifacts/b-v2/manifest.txt" > "$TD/artifacts/wrong-profile/manifest.txt"
"$SRC/src/bin/duranium" manifest sign "$TD/artifacts/wrong-profile" "$TESTKEY"

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/wrong-arch"
sed 's/^architecture=.*/architecture=x86_64/' "$TD/artifacts/b-v2/manifest.txt" > "$TD/artifacts/wrong-arch/manifest.txt"
"$SRC/src/bin/duranium" manifest sign "$TD/artifacts/wrong-arch" "$TESTKEY"

copy_variant "$TD/artifacts/b-v2" "$TD/artifacts/wrong-hardware"
sed 's/^hardware_target=.*/hardware_target=krane-mt8183/' "$TD/artifacts/b-v2/manifest.txt" > "$TD/artifacts/wrong-hardware/manifest.txt"
"$SRC/src/bin/duranium" manifest sign "$TD/artifacts/wrong-hardware" "$TESTKEY"

log "building test-data disk"
rm -f "$OUT/testdata.img"
mke2fs -t ext4 -F -L DURANIUM_TEST -d "$TD" "$OUT/testdata.img" "${TESTDATA_MB}M" >/dev/null 2>&1

log "fixture ready"
printf 'fixture: %s\n' "$OUT/duranium-fixture.img"
printf 'testdata: %s\n' "$OUT/testdata.img"
printf 'keys: %s\n' "$OUT/keys"
