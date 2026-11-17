#!/bin/sh
# LAB profile: interactive experiment bench (tooling is scp'd by the driver).
set -e
# lab profile: SSH tunnels are a workflow requirement (core defaults to no)
sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config.d/00-alloy.conf
apk add python3 git tmux htop 2>&1 | tail -1
mkdir -p /opt/alloy
chmod 755 /opt/alloy
