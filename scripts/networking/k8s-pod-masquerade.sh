#!/bin/bash
# SNAT for Kubernetes pod traffic leaving zangetsu. Install on zangetsu only.
#
# Why this exists at all:
#   Cilium masquerades pod traffic with iptables. On this host it cannot.
#   tailscaled runs with TS_DEBUG_FIREWALL_MODE=nftables, forced because the
#   RPi kernel has no legacy ip_tables (see the Tailscale entry in
#   CONVENTIONS.md), and it writes native nft rules into the nat, mangle and
#   filter tables. iptables-nft then refuses those tables as "incompatible",
#   so Cilium's reconciliation fails and it installs no masquerade rules.
#   Result: pods on this node send packets with a 10.245.x.x source address
#   that nothing can route back, and they have no internet at all.
#
#   The upstream answer is bpf.masquerade, which needs kube-proxy replacement,
#   which needs CO-RE, which needs BTF in the kernel. This kernel has none.
#   See PM-0009 and PM-0012 in the platform-engineering-labs repo.
#
# So the masquerade rule is written here, by hand, in nftables, which works
# fine on this host. Only iptables does not.
#
# The rule lives in its own table. It never touches "ip nat", which
# iptables-nft manages and which is already in the state described above.
# Nothing else writes to this table, so reconciliation is not a concern.
#
# Install:
#   sudo cp /opt/homelab/scripts/systemd/k8s-pod-masquerade.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now k8s-pod-masquerade.service
#
# Idempotent: the table is deleted and rebuilt on every run, so running it
# again is always safe.
set -euo pipefail

POD_CIDR="${POD_CIDR:-10.245.0.0/16}"
TABLE="k8s-pod-masq"

# The interface the default route uses. Explicit override with IFACE=... for
# the case where that is not the one carrying pod egress.
IFACE="${IFACE:-$(ip -4 route show default | awk '{print $5; exit}')}"

if [ -z "$IFACE" ]; then
  echo "no default route interface found, refusing to guess" >&2
  exit 1
fi

nft delete table ip "$TABLE" 2>/dev/null || true

nft add table ip "$TABLE"
# priority srcnat + 10: after the nat table's POSTROUTING, so if Cilium ever
# manages to install its own rules again they take effect first and this one
# becomes dead weight rather than a conflict.
nft add chain ip "$TABLE" postrouting \
  '{ type nat hook postrouting priority 110; policy accept; }'
# Masquerade pod traffic leaving the node, except traffic to other pods, which
# is carried by the VXLAN tunnel and must keep its source address.
nft add rule ip "$TABLE" postrouting \
  ip saddr "$POD_CIDR" ip daddr != "$POD_CIDR" oifname "$IFACE" counter masquerade

echo "✓ masquerade rule installed: $POD_CIDR out of $IFACE"
nft list table ip "$TABLE"
