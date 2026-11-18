#!/bin/sh
# Build a postmarketOS/Nura qemu-aarch64 base image from scratch (Docker).
#
# VERIFIED WORKING FLOW (don't regress):
#  1. pmbootstrap work dir must be container-native (/home/pmos/pmwork), NOT
#     a macOS bind mount — virtiofs breaks chpasswd/shadow locking.
#  2. `pmbootstrap install` dies at losetup+udev in plain docker: rootfs is
#     still built fine (chroot_rootfs_qemu-aarch64); the partitioning step
#     fails (/dev/loop0p2 never appears — container kernel loop max_part=0).
#     => assemble the disk manually (this script does that).
#  3. Rootfs from pmbootstrap has PLACEHOLDER /etc/fstab — the pmOS initramfs
#     then can't find /boot and drops into the debug shell every boot.
#     => inject real fstab (/dev/vda1 /boot, /dev/vda2 /) via debugfs.
#  4. Boot ESP needs: loader/entries/pmos.conf with `linux vmlinuz`,
#     `initrd initramfs`, EFI/BOOT/BOOTAA64.EFI (systemd-boot).
#  5. e2fsck -f + resize2fs the root fs offline so no resize is attempted.
#
# SECURITY: the container is NOT --privileged (SYS_ADMIN + loop devices only)
# and the pmos sudoers entry is scoped. The reproducible ALLOY floor path
# (alloy/build-core.sh) uses neither Docker nor these privileges.
#
# Usage:
#   PMOS_PASS=… ./pmbootstrap-docker.sh base [outdir]
#       env: DEVICE (qemu-aarch64) UI (console) PMB_TAG (3.12.1) PMOS_USER (user)
#   ./pmbootstrap-docker.sh setup|shell|fixup|export
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="pmb-kukui-lab"
WORK_HOST="$HOME/.local/var/pmbootstrap"
PMWORK=/home/pmos/pmwork
PMB_TAG="${PMB_TAG:-3.12.1}"
DEVICE="${DEVICE:-qemu-aarch64}"
UI="${UI:-console}"
PMOS_USER="${PMOS_USER:-user}"

ensure_container() {
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    mkdir -p "$WORK_HOST"
    docker run -d --name "$CONTAINER" \
      --cap-add SYS_ADMIN \
      --device /dev/loop-control \
      $(for i in 0 1 2 3 4 5 6 7; do echo --device /dev/loop$i; done) \
      -v "$WORK_HOST:/home/pmos/.local/var/pmbootstrap" \
      -v "$REPO_DIR:/work" \
      -w /work ubuntu:24.04 sleep infinity
    docker exec "$CONTAINER" bash -lc "
      apt-get update -qq && apt-get install -y -qq git python3 openssl sudo parted \
        e2fsprogs dosfstools qemu-user-static kpartx multipath-tools e2tools mtools fdisk
      test -d /opt/pmbootstrap || git clone --depth 1 -q \
        https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git /opt/pmbootstrap
      ln -sf /opt/pmbootstrap/pmbootstrap.py /usr/local/bin/pmbootstrap
      id pmos 2>/dev/null || useradd -m -s /bin/bash pmos
      printf '%s\n' \
        'pmos ALL=(root) NOPASSWD: /sbin/apk, /usr/sbin/chroot, /sbin/losetup,' \
        ' /bin/mount, /bin/umount, /sbin/mkfs.*, /usr/sbin/mkfs.*, /sbin/mknod,' \
        ' /usr/bin/mkinitfs, /usr/bin/pmbootstrap' \
        > /etc/sudoers.d/pmos
      chmod 440 /etc/sudoers.d/pmos
      chown -R pmos:pmos /home/pmos"
  else
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
}

assemble_disk() {
  # Runs inside the container as root; args: rootfs dir, output raw name
  docker exec "$CONTAINER" bash -lc '
    set -e
    R="$1"; RAW="$2"
    cd /home/pmos/out
    mkfs.ext4 -F -L pmOS_root -d "$R" rootfs2.ext4 3500M
    e2fsck -f -y rootfs2.ext4 >/dev/null; resize2fs rootfs2.ext4 >/dev/null; e2fsck -f -y rootfs2.ext4 >/dev/null
    mkfs.vfat -C -F 32 -n PMOS_BOOT pmboot.fat 524288 >/dev/null
    mcopy -s -i pmboot.fat "$R"/boot/* ::
    printf "title postmarketOS\nsort-key postmarketOS\nlinux vmlinuz\n\ninitrd initramfs\noptions console=tty1 console=ttyAMA0,115200 psi=1\n" > /tmp/pmos.conf
    mcopy -o -i pmboot.fat /tmp/pmos.conf ::/loader/entries/pmos.conf
    printf "/dev/vda1  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,utf8  0  1\n/dev/vda2  /      ext4  rw,relatime  0  1\n" > /tmp/fstab.new
    debugfs -w -R "rm /etc/fstab" rootfs2.ext4 >/dev/null 2>&1 || true
    debugfs -w -R "write /tmp/fstab.new /etc/fstab" rootfs2.ext4 >/dev/null
    truncate -s 4200M "$RAW"
    parted -s "$RAW" mklabel gpt \
      mkpart ESP fat32 1MiB 513MiB set 1 esp on name 1 pmOS_boot \
      mkpart ROOT ext4 513MiB 100% name 2 pmOS_root
    dd if=pmboot.fat of="$RAW" bs=1M seek=1 conv=notrunc status=none
    dd if=rootfs2.ext4 of="$RAW" bs=1M seek=513 conv=notrunc status=none
    echo "assembled: /home/pmos/out/$RAW"
  ' _ "$1" "$2"
}

case "${1:-help}" in
  base)
    : "${PMOS_PASS:?set PMOS_PASS to the image user password}"
    OUTDIR="${2:-$REPO_DIR/alloy/build}"
    mkdir -p "$OUTDIR"
    ensure_container
    docker exec pmb-kukui-lab bash -lc "cd /opt/pmbootstrap && git fetch --tags -q && git checkout -q '$PMB_TAG'"
    docker exec -u pmos pmb-kukui-lab bash -lc "
      set -e
      cd /home/pmos
      if [ ! -d ~/.local/var/pmbootstrap/cache_git/pmaports ]; then
        yes \"\" | pmbootstrap init --shallow-initial-clone
      fi
      pmbootstrap config work '$PMWORK'
      pmbootstrap config device '$DEVICE'
      pmbootstrap config ui '$UI'
      pmbootstrap config user '$PMOS_USER'
      pmbootstrap install --password \"$PMOS_PASS\" || true   # loop step fails in docker by design"
    docker exec pmb-kukui-lab mkdir -p /home/pmos/out
    STAMP="$(date +%Y%m%d-%H%M)"
    RAW="base-$DEVICE-$STAMP.raw"
    assemble_disk "$PMWORK/chroot_rootfs_$DEVICE" "$RAW"
    HOST_OUT="$OUTDIR/base-$DEVICE-$UI-$STAMP.qcow2"
    docker cp "pmb-kukui-lab:/home/pmos/out/$RAW" /tmp/"$RAW" >/dev/null
    qemu-img convert -O qcow2 /tmp/"$RAW" "$HOST_OUT"
    rm -f /tmp/"$RAW"
    echo "==> base image: $HOST_OUT"
    shasum -a 256 "$HOST_OUT"
    ;;
  setup)
    ensure_container
    docker exec -u pmos "$CONTAINER" bash -lc "
      python3 /opt/pmbootstrap/pmbootstrap.py init --shallow-initial-clone <<< ''
      python3 /opt/pmbootstrap/pmbootstrap.py config work $PMWORK
      python3 /opt/pmbootstrap/pmbootstrap.py config device $DEVICE
      python3 /opt/pmbootstrap/pmbootstrap.py config ui $UI
      python3 /opt/pmbootstrap/pmbootstrap.py config user $PMOS_USER"
    echo "==> next: PMOS_PASS=… $0 base"
    ;;
  fixup)
    # Legacy: assemble from the current rootfs with fixed names.
    ensure_container
    assemble_disk "$PMWORK/chroot_rootfs_qemu-aarch64" pmos-disk2.raw
    docker cp "$CONTAINER:/home/pmos/out/pmos-disk2.raw" /tmp/pmos-disk2.raw >/dev/null
    qemu-img convert -O qcow2 /tmp/pmos-disk2.raw "$REPO_DIR/images/pmos-qemu-aarch64.qcow2"
    rm -f /tmp/pmos-disk2.raw
    echo "==> $REPO_DIR/images/pmos-qemu-aarch64.qcow2"
    ;;
  export) docker exec -u pmos -it "$CONTAINER" bash || true ;;
  shell)  ensure_container; docker exec -u pmos -it "$CONTAINER" bash ;;
  *) echo "usage: $0 {base [outdir]|setup|fixup|shell}"; exit 1 ;;
esac
