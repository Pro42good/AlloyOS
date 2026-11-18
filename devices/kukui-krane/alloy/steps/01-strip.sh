#!/bin/sh
# ALLOY stage 01 — the strip: pin the keep-list, cascade out the GUI world.
set -e
apk add mesa mesa-dri-gallium mesa-egl mesa-gbm pipewire wireplumber \
    alsa-lib alsa-utils alsa-ucm-conf alsa-plugins-pulse libinput \
    networkmanager openssh bluez wpa_supplicant polkit dbus-broker 2>&1 | tail -1
DELS=""
for p in calls chatty decibels firefox-esr flatpak font-droid \
    font-droid-nonlatin font-twemoji fprintd g4music gnome-calculator \
    gnome-calendar gnome-clocks gnome-console gnome-contacts gnome-maps \
    gnome-text-editor gnome-user-share gnome-weather gst-libav \
    gst-plugins-bad gst-plugins-good gst-plugins-rs-dav1d gvfs-full lang \
    loupe lpa-gtk mobile-config-firefox nautilus papers phosh-mobile-settings \
    phosh-tour postmarketos-tweaks-setting-definitions postmarketos-ui-phosh \
    rygel showtime snapshot ttyescape tuned-ppd vvmplayer cups; do
  apk info -e "$p" >/dev/null 2>&1 && DELS="$DELS $p"
done
[ -n "$DELS" ] && apk del $DELS 2>&1 | tail -1 || echo "(no GUI-era packages present)"
apk add agetty 2>&1 | tail -1
apk stats | grep -E '^  (packages|bytes)'
