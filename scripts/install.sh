#!/usr/bin/env bash
# Alloy OS Installer
# Usage: sudo ./install.sh

set -euo pipefail

# Variables:
MANDATORY_PKGS="plasma-desktop plasma-wayland-protocols imagemagick jq fastfetch zstd util-linux waydroid lxc zram-init"

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

# Start applying tweaks

if [ -f "/usr/lib/libexec/baloorunner" ]; then
    echo "Disabling Baloo..."
    mkdir -p /etc/xdg
    printf "[Basic Settings]\nIndexing-Enabled=false\n" > /etc/xdg/baloofilerc
    pkill baloo || true
    chmod -x /usr/lib/libexec/baloorunner
fi
