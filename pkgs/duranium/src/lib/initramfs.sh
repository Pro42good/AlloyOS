#!/bin/sh
# Initramfs boot logic.
#
# The initramfs is deliberately small: it mounts BOOT, validates the slot's
# metadata and boot artifacts, mounts the chosen system image read-only, mounts
# STATE and binds declared persistent paths, then switch_roots.
#
# There is one initramfs per slot so kernel/initramfs updates are A/B too.

initramfs_reboot_or_poweroff() {
    sync 2>/dev/null || true
    reboot -f 2>/dev/null || poweroff -f 2>/dev/null || exit 1
}

initramfs_load_modules() {
    # Kernels that build FAT as a module (e.g. Alpine linux-virt on x86_64)
    # cannot mount the FAT ESP without it. The modules are optional: the
    # aarch64 fixture kernel has everything built in and ships none. Load
    # order matters: busybox insmod does not resolve dependencies, and
    # vfat requires the nls codepages and fat first.
    local _m
    for _m in virtio_blk nls_cp437 nls_ascii nls_utf8 fat vfat crc16 crc32c crc32c_generic mbcache jbd2 ext4; do
        if [ -e "/modules/$_m.ko" ]; then
            if ! insmod "/modules/$_m.ko" 2>/dev/null; then
                printf 'duranium: warning: insmod %s failed\n' "$_m" >&2
            fi
        fi
    done
    return 0
}

initramfs_mount_boot() {
    local _dev
    dur_mkdir "$DURANIUM_BOOT_MNT" || return 1
    if dur_is_mounted "$DURANIUM_BOOT_MNT"; then
        return 0
    fi
    _dev=$DURANIUM_BOOT_DEV
    if [ -z "$_dev" ]; then
        _dev=$(backend_resolve_label "$DURANIUM_BOOT_PARTLABEL" "") || {
            dur_err "cannot find BOOT partition ($DURANIUM_BOOT_PARTLABEL)"
            return 1
        }
    fi
    mount -t vfat -o rw "$_dev" "$DURANIUM_BOOT_MNT" 2>/dev/null || {
        dur_err "cannot mount BOOT $_dev"
        return 1
    }
    return 0
}

initramfs_mount_recovery_root() {
    local _dev
    dur_mkdir "$DURANIUM_RECOVERY_MNT" || return 1
    if ! dur_is_mounted "$DURANIUM_RECOVERY_MNT"; then
        _dev=$DURANIUM_RECOVERY_DEV
        if [ -z "$_dev" ]; then
            _dev=$(backend_resolve_label "$DURANIUM_RECOVERY_PARTLABEL" "") || {
                dur_err "cannot find RECOVERY partition"
                return 1
            }
        fi
        mount -t ext4 -o rw "$_dev" "$DURANIUM_RECOVERY_MNT" 2>/dev/null || {
            dur_err "cannot mount RECOVERY $_dev"
            return 1
        }
    fi
    dur_mkdir "$DURANIUM_RECOVERY_MNT/boot" || return 1
    if ! dur_is_mounted "$DURANIUM_RECOVERY_MNT/boot"; then
        mount --bind "$DURANIUM_BOOT_MNT" "$DURANIUM_RECOVERY_MNT/boot" 2>/dev/null || true
    fi
    if [ -d "$DURANIUM_NEWROOT/state" ]; then
        dur_mkdir "$DURANIUM_RECOVERY_MNT/state" || true
        if ! dur_is_mounted "$DURANIUM_RECOVERY_MNT/state"; then
            mount --bind "$DURANIUM_NEWROOT/state" "$DURANIUM_RECOVERY_MNT/state" 2>/dev/null || true
        fi
    fi
    return 0
}

initramfs_boot_recovery() {
    dur_warn "booting recovery environment"
    if ! initramfs_mount_recovery_root; then
        dur_err "recovery environment is not bootable"
        initramfs_reboot_or_poweroff
    fi
    dur_mkdir "$DURANIUM_RECOVERY_MNT/proc" 2>/dev/null || true
    dur_mkdir "$DURANIUM_RECOVERY_MNT/sys" 2>/dev/null || true
    dur_mkdir "$DURANIUM_RECOVERY_MNT/dev" 2>/dev/null || true
    dur_mkdir "$DURANIUM_RECOVERY_MNT/run" 2>/dev/null || true
    mount --move /dev "$DURANIUM_RECOVERY_MNT/dev" 2>/dev/null || true
    mount --move /proc "$DURANIUM_RECOVERY_MNT/proc" 2>/dev/null || true
    mount --move /sys "$DURANIUM_RECOVERY_MNT/sys" 2>/dev/null || true
    mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$DURANIUM_RECOVERY_MNT/run" 2>/dev/null || true
    exec switch_root "$DURANIUM_RECOVERY_MNT" /sbin/init
}

initramfs_main() {
    local _img_slot _mode _mode_file _rc _slot _why
    export PATH=/sbin:/bin:/usr/sbin:/usr/bin
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sys /sys 2>/dev/null || true
    mount -t devtmpfs dev /dev 2>/dev/null || true
    dur_mkdir /run || true
    mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /run 2>/dev/null || true
    dur_mkdir "$DURANIUM_RUN" || true

    export DURANIUM_INITRAMFS=1
    initramfs_load_modules
    initramfs_mount_boot || initramfs_reboot_or_poweroff

    _mode_file=$(cat /etc/duranium/mode 2>/dev/null || true)
    _mode=$(dur_cmdline_value duranium.mode 2>/dev/null || true)
    if [ "$_mode" = "recovery" ] || [ "$_mode_file" = "recovery" ]; then
        initramfs_boot_recovery
    fi

    _slot=$(dur_cmdline_value duranium.slot 2>/dev/null || true)
    if ! dur_is_slot "$_slot"; then
        dur_err "kernel command line does not identify a Duranium slot"
        initramfs_boot_recovery
    fi
    _img_slot=$(cat /etc/duranium/slot 2>/dev/null || true)
    if [ -n "$_img_slot" ] && [ "$_img_slot" != "$_slot" ]; then
        dur_err "slot marker mismatch: initramfs=$_img_slot cmdline=$_slot"
        initramfs_boot_recovery
    fi

    # Boot-record consumes/synchronizes the systemd-boot attempt counter and
    # writes the boot ID used by mark-good.
    slot_boot_record "$_slot"
    _rc=$?
    if [ "$_rc" -eq 2 ]; then
        initramfs_boot_recovery
    elif [ "$_rc" -eq 3 ]; then
        initramfs_reboot_or_poweroff
    elif [ "$_rc" -ne 0 ]; then
        initramfs_reboot_or_poweroff
    fi

    # Verify kernel, initramfs and - for PENDING slots, always - the root
    # image. This MUST run before backend_mount_slot_ro below: hashing a
    # mounted ext4's raw device diverges from the installed image (the
    # kernel keeps journal/superblock buffers in the block-device page
    # cache and read-only mounts never write them back).
    if ! slot_boot_verify "$_slot"; then
        _why=${DURANIUM_LAST_ERROR:-boot artifact verification failed}
        slot_boot_fail "$_slot" "$_why"
        _rc=$?
        if [ "$_rc" -eq 2 ]; then
            initramfs_boot_recovery
        fi
        initramfs_reboot_or_poweroff
    fi

    dur_mkdir "$DURANIUM_NEWROOT" || initramfs_reboot_or_poweroff
    if ! dur_is_mounted "$DURANIUM_NEWROOT"; then
        if ! backend_mount_slot_ro "$_slot" "$DURANIUM_NEWROOT"; then
            _why=${DURANIUM_LAST_ERROR:-slot mount failed}
            slot_boot_fail "$_slot" "$_why"
            _rc=$?
            if [ "$_rc" -eq 2 ]; then
                initramfs_boot_recovery
            fi
            initramfs_reboot_or_poweroff
        fi
    fi

    slot_reconcile || dur_warn "boot reconciliation reported an error"

    # Mount STATE and bind only declared paths. A pending slot that cannot
    # reach its STATE must not be confirmed GOOD.
    if ! state_prepare_mounts "$DURANIUM_NEWROOT"; then
        _why=${DURANIUM_LAST_ERROR:-STATE preparation failed}
        if meta_load_slot "$_slot" && [ "$MS_status" = "PENDING" ]; then
            slot_boot_fail "$_slot" "$_why"
            initramfs_reboot_or_poweroff
        fi
        dur_warn "STATE is unavailable; booting read-only with health degraded"
    fi

    # Move the runtime boot record into the new root's tmpfs /run.
    dur_mkdir "$DURANIUM_NEWROOT/run/duranium" 2>/dev/null || true
    if [ -r "$DURANIUM_RUN/boot.env" ]; then
        cp "$DURANIUM_RUN/boot.env" "$DURANIUM_NEWROOT/run/duranium/boot.env" 2>/dev/null || true
    fi
    printf 'slot=%s\n' "$_slot" > "$DURANIUM_NEWROOT/run/duranium/initramfs-slot" 2>/dev/null || true

    # Expose the BOOT FAT as /boot in the new root. The updater and mark-good
    # write metadata and boot entries there.
    dur_mkdir "$DURANIUM_NEWROOT/boot" 2>/dev/null || true
    if ! dur_is_mounted "$DURANIUM_NEWROOT/boot"; then
        mount --bind "$DURANIUM_BOOT_MNT" "$DURANIUM_NEWROOT/boot" 2>/dev/null || \
            dur_warn "could not bind BOOT at $DURANIUM_NEWROOT/boot"
    fi

    dur_mkdir "$DURANIUM_NEWROOT/dev" 2>/dev/null || true
    dur_mkdir "$DURANIUM_NEWROOT/proc" 2>/dev/null || true
    dur_mkdir "$DURANIUM_NEWROOT/sys" 2>/dev/null || true
    mount --move /dev "$DURANIUM_NEWROOT/dev" 2>/dev/null || true
    mount --move /proc "$DURANIUM_NEWROOT/proc" 2>/dev/null || true
    mount --move /sys "$DURANIUM_NEWROOT/sys" 2>/dev/null || true

    exec switch_root "$DURANIUM_NEWROOT" /sbin/init
}
