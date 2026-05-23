#!/bin/sh
if [ -z "$ALLOY_BOOTSTRAPPED" ]; then
    apk add bash 2>/dev/null
    export ALLOY_BOOTSTRAPPED=1
    exec bash "$0" "$@"
fi

#!/usr/bin/env bash
# Alloy OS Installer
# Usage: sudo ./install.sh

set -euo pipefail
trap 'echo "Error at line $LINENO, exiting."; exit 1' ERR

# Variables:
MANDATORY_PKGS="plasma-desktop plasma-wayland-protocols imagemagick jq fastfetch zstd util-linux waydroid lxc zram-init"
DISABLE_TUNED_DEFAULT="no"
DISABLE_PULSE_DEFAULT="yes"
DISABLE_BT_DEFAULT="no"
DISABLE_SSH_DEFAULT="no"
DISABLE_KACCESS_DEFAULT="yes"
DISABLE_GEOCLUE_DEFAULT="yes"
DISABLE_OBEX_DEFAULT="yes"
DISABLE_AVAHI_DEFAULT="yes"
DISABLE_KUPD_DEFAULT="yes"
DISABLE_MPRIS_DEFAULT="no"

# Baseline requirements check.
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." 
   exit 1
fi
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "postmarketos" ] && [ "$(uname -m)" = "aarch64" ]; then
        echo "System validated: postmarketOS on aarch64 detected."
    else
        echo "Rejection: Environment does not meet requirements (aarch64 and postmarketOS required)."
        exit 1
    fi
else
    echo "Error: /etc/os-release not found. Architecture was $(uname -m)."
    exit 1
fi
for pkg in $MANDATORY_PKGS; do
    if ! apk info -e "$pkg" > /dev/null; then
        printf "Package '%s' is missing. Install it now? [y/N]: " "$pkg"
        read -r response
        
        case "$response" in
            [yY][eE][sS]|[yY]) 
                echo "Installing $pkg..."
                apk add "$pkg" || { echo "Failed to install $pkg"; exit 1; }
                ;;
            *)
                echo "Error: Required package '$pkg' is not installed. User aborted."
                exit 1
                ;;
        esac
    fi
done

# Start prepping the system and applying tweaks
echo "The Highlighted Letter in the y/n Is the Default option"
read -r -p "Press Enter to continue..."
if [ -z "$DISABLE_TUNED" ]; then
    printf "tuned and tuned-ppd are performance/power tuning daemons. Disable them? [y/N]: "
    read -r response
    response="${response:-$DISABLE_TUNED_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_TUNED="yes" ;;
        *) DISABLE_TUNED="no" ;;
    esac
fi
if [ "$DISABLE_TUNED" = "yes" ]; then
    if [ -f "/usr/sbin/tuned" ]; then
        echo "Disabling tuned..."
        pkill tuned || true
        chmod -x /usr/sbin/tuned
    fi
    if [ -f "/usr/sbin/tuned-ppd" ]; then
        echo "Disabling tuned-ppd..."
        pkill tuned-ppd || true
        chmod -x /usr/sbin/tuned-ppd
    fi
fi

if [ -z "$DISABLE_PULSE" ]; then
    printf "PulseAudio is redundant alongside PipeWire. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_PULSE_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_PULSE="yes" ;;
        *) DISABLE_PULSE="no" ;;
    esac
fi
if [ "$DISABLE_PULSE" = "yes" ]; then
    if [ -f "/usr/bin/pulseaudio" ]; then
        echo "Disabling PulseAudio..."
        pkill pulseaudio || true
        chmod -x /usr/bin/pulseaudio
    fi
fi

if [ -z "$DISABLE_BT" ]; then
    printf "Bluetooth support varies by device. Disable bluetoothd? [y/N]: "
    read -r response
    response="${response:-$DISABLE_BT_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_BT="yes" ;;
        *) DISABLE_BT="no" ;;
    esac
fi
if [ "$DISABLE_BT" = "yes" ]; then
    if [ -f "/usr/lib/bluetooth/bluetoothd" ]; then
        echo "Disabling bluetoothd..."
        pkill bluetoothd || true
        chmod -x /usr/lib/bluetooth/bluetoothd
    fi
fi

if [ -z "$DISABLE_MPRIS" ]; then
    printf "mpris-proxy handles Bluetooth media controls. Disable it? [y/N]: "
    read -r response
    response="${response:-$DISABLE_MPRIS_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_MPRIS="yes" ;;
        *) DISABLE_MPRIS="no" ;;
    esac
fi
if [ "$DISABLE_MPRIS" = "yes" ]; then
    if [ -f "/usr/bin/mpris-proxy" ]; then
        echo "Disabling mpris-proxy..."
        pkill mpris-proxy || true
        chmod -x /usr/bin/mpris-proxy
    fi
fi

if [ -z "$DISABLE_SSH" ]; then
    printf "sshd allows remote access to your device. Disable it? [y/N]: "
    read -r response
    response="${response:-$DISABLE_SSH_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_SSH="yes" ;;
        *) DISABLE_SSH="no" ;;
    esac
fi
if [ "$DISABLE_SSH" = "yes" ]; then
    if [ -f "/usr/sbin/sshd.pam" ]; then
        echo "Disabling sshd..."
        pkill sshd || true
        chmod -x /usr/sbin/sshd.pam
    fi
fi

if [ -z "$DISABLE_KACCESS" ]; then
    printf "kaccess provides accessibility features. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_KACCESS_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_KACCESS="yes" ;;
        *) DISABLE_KACCESS="no" ;;
    esac
fi
if [ "$DISABLE_KACCESS" = "yes" ]; then
    if [ -f "/usr/bin/kaccess" ]; then
        echo "Disabling kaccess..."
        pkill kaccess || true
        chmod -x /usr/bin/kaccess
    fi
fi

if [ -z "$DISABLE_GEOCLUE" ]; then
    printf "GeoClue provides location services. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_GEOCLUE_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_GEOCLUE="yes" ;;
        *) DISABLE_GEOCLUE="no" ;;
    esac
fi
if [ "$DISABLE_GEOCLUE" = "yes" ]; then
    if [ -f "/usr/libexec/geoclue-2.0/demos/agent" ]; then
        echo "Disabling GeoClue agent..."
        pkill geoclue || true
        chmod -x /usr/libexec/geoclue-2.0/demos/agent
    fi
fi

if [ -z "$DISABLE_OBEX" ]; then
    printf "obexd handles Bluetooth file transfers. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_OBEX_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_OBEX="yes" ;;
        *) DISABLE_OBEX="no" ;;
    esac
fi
if [ "$DISABLE_OBEX" = "yes" ]; then
    if [ -f "/usr/lib/bluetooth/obexd" ]; then
        echo "Disabling obexd..."
        pkill obexd || true
        chmod -x /usr/lib/bluetooth/obexd
    fi
fi

if [ -z "$DISABLE_AVAHI" ]; then
    printf "Avahi handles local network discovery. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_AVAHI_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_AVAHI="yes" ;;
        *) DISABLE_AVAHI="no" ;;
    esac
fi
if [ "$DISABLE_AVAHI" = "yes" ]; then
    if [ -f "/usr/sbin/avahi-daemon" ]; then
        echo "Disabling avahi-daemon..."
        pkill avahi-daemon || true
        chmod -x /usr/sbin/avahi-daemon
    fi
fi

if [ -z "$DISABLE_KUPD" ]; then
    printf "kunifiedpush-distributor handles push notifications. Disable it? [Y/n]: "
    read -r response
    response="${response:-$DISABLE_KUPD_DEFAULT}"
    case "$response" in
        [yY]*) DISABLE_KUPD="yes" ;;
        *) DISABLE_KUPD="no" ;;
    esac
fi
if [ "$DISABLE_KUPD" = "yes" ]; then
    if [ -f "/usr/bin/kunifiedpush-distributor" ]; then
        echo "Disabling kunifiedpush-distributor..."
        pkill kunifiedpush-distributor || true
        chmod -x /usr/bin/kunifiedpush-distributor
    fi
fi

if [ -f "/usr/lib/libexec/baloorunner" ]; then
    echo "Disabling Baloo..."
    mkdir -p /etc/xdg
    printf "[Basic Settings]\nIndexing-Enabled=false\n" > /etc/xdg/baloofilerc
    pkill baloo || true
    chmod -x /usr/lib/libexec/baloorunner
fi

if [ -f "/usr/sbin/ModemManager" ]; then
    echo "Disabling ModemManager..."
    pkill ModemManager || true
    chmod -x /usr/sbin/ModemManager
fi

if [ -f "/usr/libexec/evolution-source-registry" ]; then
    echo "Disabling Evolution source registry..."
    pkill evolution-source-registry || true
    chmod -x /usr/libexec/evolution-source-registry
fi

if [ -f "/usr/libexec/evolution-addressbook-factory" ]; then
    echo "Disabling Evolution address book factory..."
    pkill evolution-addressbook-factory || true
    chmod -x /usr/libexec/evolution-addressbook-factory
fi

if [ -f "/usr/libexec/goa-daemon" ]; then
    echo "Disabling GNOME Online Accounts daemon..."
    pkill goa-daemon || true
    chmod -x /usr/libexec/goa-daemon
fi

if [ -f "/usr/libexec/goa-identity-service" ]; then
    echo "Disabling GNOME Online Accounts identity service..."
    pkill goa-identity-service || true
    chmod -x /usr/libexec/goa-identity-service
fi

if [ -f "/usr/bin/spectacle" ]; then
    echo "Disabling Spectacle dbus daemon..."
    pkill spectacle || true
    chmod -x /usr/bin/spectacle
fi

if [ -f "/usr/lib/libexec/DiscoverNotifier" ]; then
    echo "Disabling KDE Discover notifier..."
    pkill DiscoverNotifier || true
    chmod -x /usr/lib/libexec/DiscoverNotifier
fi

# Zram and KSM config

# Kernel things, core pinning, schedualing, storage, ect

# waydroid setup

# MicroG for waydroid

# KDE config

# User Customization

# OS Branding (Switching Postmarket OS Identifiers with Alloy OS Identifiers but with credit to postmarket os)
