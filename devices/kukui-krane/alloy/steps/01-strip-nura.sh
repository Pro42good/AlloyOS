#!/bin/sh
# Stage 01 (Nura console base): keep-list pins + optional GUI-era cleanup.
set -e
apk add mesa mesa-dri-gallium mesa-egl mesa-gbm pipewire wireplumber \
    alsa-lib alsa-utils alsa-ucm-conf alsa-plugins-pulse libinput \
    networkmanager openssh bluez wpa_supplicant polkit dbus-broker \
    kbd-bkeymaps 2>&1 | tail -1
DELS=""
for p in font-droid font-droid-nonlatin font-twemoji lang avahi tuned-ppd ttyescape; do
  apk info -e "$p" >/dev/null 2>&1 && DELS="$DELS $p"
done
[ -n "$DELS" ] && apk del $DELS 2>&1 | tail -1 || echo "(no GUI-era packages to remove)"
apk stats | grep -E '^  (packages|bytes)'
