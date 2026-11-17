#!/bin/sh
# ALLOY stage 03 — udev hwdb diet: drop name-lookup databases, regenerate trie.
set -e
rm -f /usr/lib/udev/hwdb.d/20-OUI.hwdb \
      /usr/lib/udev/hwdb.d/20-acpi-vendor.hwdb \
      /usr/lib/udev/hwdb.d/20-bluetooth-vendor-product.hwdb \
      /usr/lib/udev/hwdb.d/20-dmi-id.hwdb \
      /usr/lib/udev/hwdb.d/20-sdio-vendor-model.hwdb \
      /usr/lib/udev/hwdb.d/20-pci-vendor-model.hwdb \
      /usr/lib/udev/hwdb.d/20-usb-vendor-model.hwdb \
      /usr/lib/udev/hwdb.d/80-ieee1394-unit-function.hwdb \
      /usr/lib/udev/hwdb.d/40-imds.hwdb \
      /usr/lib/udev/hwdb.d/60-autosuspend-fingerprint-reader.hwdb \
      /usr/lib/udev/hwdb.d/60-tpm2.hwdb
systemd-hwdb update
du -sk /usr/lib/udev/hwdb.d /etc/udev/hwdb.bin
