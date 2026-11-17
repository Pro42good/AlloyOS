# Build postmarketOS qemu-aarch64 from source (pmbootstrap inside Docker).
#
# VERIFIED WORKING FLOW (don't regress):
#  1. pmbootstrap work dir must be container-native (/home/pmos/pmwork), NOT
#     a macOS bind mount — virtiofs breaks chpasswd/shadow locking.
#  2. `pmbootstrap install` dies at losetup+udev in plain docker: rootfs is
#     still built fine (chroot_rootfs_qemu-aarch64); the partitioning step
#     fails (/dev/loop0p2 never appears — container kernel loop max_part=0).
#     => assemble the disk manually (scripts below).
#  3. Rootfs from pmbootstrap has PLACEHOLDER /etc/fstab — the pmOS initramfs
#     then can't find /boot and drops into the debug shell every boot.
#     => inject real fstab (/dev/vda1 /boot, /dev/vda2 /) via debugfs.
#  4. Boot ESP needs: loader/entries/pmos.conf with `linux vmlinuz`,
#     `initrd initramfs`, EFI/BOOT/BOOTAA64.EFI (systemd-boot).
#     Remove `quiet splash` + `pmos.force-partition-resize` from options for
#     serial visibility and clean first boot.
#  5. e2fsck -f + resize2fs the root fs offline so no resize is attempted.
#
# Run: ./pmbootstrap-docker.sh {setup|shell|fixup|export}
#
# SECURITY_AUDIT2: this is the UNTRUSTED-legacy build path — kept for
# pmbootstrap-native rebuilds only (SYS_ADMIN + mount/umount sudoers remain
# by necessity of chroot builds; the reproducible ALLOY path is
# alloy/build-core.sh and uses neither Docker nor these privileges).
# Supply chain: pmbootstrap pinned to v3.11.1 (the verified build version).
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="pmb-kukui-lab"
WORK_HOST="$HOME/.local/var/pmbootstrap"
PMWORK=/home/pmos/pmwork

ensure_container() {
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    mkdir -p "$WORK_HOST"
    # SECURITY_AUDIT HIGH-3: no --privileged. pmbootstrap needs SYS_ADMIN for
    # chroot mounts + the loop device nodes; nothing else. (The reproducible
    # ALLOY build path doesn't use Docker at all - see alloy/build-core.sh.)
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
      test -d /opt/pmbootstrap || git clone --depth 1 -q -b v3.11.1 \
        https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git /opt/pmbootstrap
      ln -sf /opt/pmbootstrap/pmbootstrap.py /usr/local/bin/pmbootstrap
      id pmos 2>/dev/null || useradd -m -s /bin/bash pmos
      # SECURITY_AUDIT LOW-1: scoped sudoers, not NOPASSWD:ALL
      printf '%s\n' \
        'pmos ALL=(root) NOPASSWD: /sbin/apk, /usr/sbin/chroot, /sbin/losetup,' \
        ' /bin/mount, /bin/umount, /sbin/mkfs.*, /usr/sbin/mkfs.*, /sbin/mknod,' \
        ' /usr/bin/mkinitfs, /usr/bin/pmbootstrap' \
        > /etc/sudoers.d/pmos
      chmod 440 /etc/sudoers.d/pmos
      chown -R pmos:pmos /home/pmos"
  else
    docker start "$CONTAINER" >/dev/null
  fi
}

case "${1:-help}" in
  setup)
    ensure_container
    docker exec -u pmos "$CONTAINER" bash -lc "
      python3 /opt/pmbootstrap/pmbootstrap.py init --shallow-initial-clone <<< ''
      python3 /opt/pmbootstrap/pmbootstrap.py config work $PMWORK
      python3 /opt/pmbootstrap/pmbootstrap.py config device qemu-aarch64
      python3 /opt/pmbootstrap/pmbootstrap.py config ui phosh
      python3 /opt/pmbootstrap/pmbootstrap.py config user user"
    echo "==> next: docker exec -u pmos -it $CONTAINER pmbootstrap install --password 147147"
    echo "    (rootfs lands in $PMWORK/chroot_rootfs_qemu-aarch64 even though the"
    echo "     final partition step fails in docker)"
    ;;
  fixup)
    # Assemble bootable disk from pmbootstrap's rootfs (works around docker losetup).
    docker exec "$CONTAINER" bash -lc '
      set -e
      R=/home/pmos/pmwork/chroot_rootfs_qemu-aarch64
      cd /home/pmos
      mkfs.ext4 -F -L pmOS_root -d $R rootfs2.ext4 3500M
      e2fsck -f -y rootfs2.ext4; resize2fs rootfs2.ext4; e2fsck -f -y rootfs2.ext4
      mkfs.vfat -C -F 32 -n PMOS_BOOT pmboot.fat 524288
      mcopy -s -i pmboot.fat $R/boot/* ::
      printf "title postmarketOS\nsort-key postmarketOS\nlinux vmlinuz\n\ninitrd initramfs\noptions console=tty1 console=ttyAMA0,115200 psi=1\n" > /tmp/pmos.conf
      mcopy -o -i pmboot.fat /tmp/pmos.conf ::/loader/entries/pmos.conf
      printf "/dev/vda1  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,utf8  0  1\n/dev/vda2  /      ext4  rw,relatime  0  1\n" > /tmp/fstab.new
      debugfs -w -R "rm /etc/fstab" rootfs2.ext4 >/dev/null 2>&1 || true
      debugfs -w -R "write /tmp/fstab.new /etc/fstab" rootfs2.ext4 >/dev/null
      truncate -s 4200M pmos-disk2.raw
      parted -s pmos-disk2.raw mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB set 1 esp on name 1 pmOS_boot \
        mkpart ROOT ext4 513MiB 100% name 2 pmOS_root
      dd if=pmboot.fat of=pmos-disk2.raw bs=1M seek=1 conv=notrunc status=none
      dd if=rootfs2.ext4 of=pmos-disk2.raw bs=1M seek=513 conv=notrunc status=none
      cp pmos-disk2.raw /work/images/pmos-qemu-aarch64.raw
      echo "==> raw image synced to /work/images/"'
    ;;
  export)
    docker exec -u pmos -it "$CONTAINER" bash || true
    ;;
  shell)
    ensure_container
    docker exec -u pmos -it "$CONTAINER" bash
    ;;
  *) echo "usage: $0 {setup|fixup|shell}"; exit 1 ;;
esac
