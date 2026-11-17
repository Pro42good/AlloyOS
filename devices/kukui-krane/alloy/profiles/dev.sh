#!/bin/sh
# DEV profile: developer workstation on the ALLOY floor.
set -e
# dev profile: SSH tunnels are a workflow requirement (core defaults to no)
sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config.d/00-alloy.conf
apk add git build-base vim tmux htop strace python3 mandoc man-pages 2>&1 | tail -1
apk stats | grep -E '^  (packages|bytes)'
