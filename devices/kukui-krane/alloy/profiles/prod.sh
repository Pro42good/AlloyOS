#!/bin/sh
# PROD profile: runtime hardening on the ALLOY floor (key-only SSH, volatile
# journal, minimal firewall — nftables installed with a small oneshot unit
# since Alpine's nftables pkg ships no systemd unit).
set -e
printf "PasswordAuthentication no\n" > /etc/ssh/sshd_config.d/10-prod.conf
mkdir -p /etc/systemd/journald.conf.d
printf "[Journal]\nStorage=volatile\n" > /etc/systemd/journald.conf.d/20-prod.conf

apk add nftables 2>&1 | tail -1
cat > /etc/nftables.nft <<'EOF'
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        tcp dport 22 accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
cat > /etc/systemd/system/nftables.service <<'EOF'
[Unit]
Description=nftables firewall (ALLOY prod)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nftables.service 2>&1 | tail -1
systemctl start nftables.service
systemctl restart sshd
echo "nft ruleset lines: $(nft list ruleset 2>/dev/null | wc -l)"
