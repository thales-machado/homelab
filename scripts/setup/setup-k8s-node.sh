#!/bin/bash
# Prepares a host as a kubeadm node: kernel modules, sysctl, the pkgs.k8s.io
# repository, and the three pinned packages.
#   setup-k8s-node.sh                -> prepares the host and lists candidates
#   setup-k8s-node.sh 1.37.4-1.1     -> also installs and holds that exact version
# The CRI is the host's existing containerd, shared with Docker: the CRI plugin
# is already enabled and SystemdCgroup is already true, so nothing is changed
# there. See "Kubernetes node" in CONVENTIONS.md.
# Rerun with a new version argument to move the pin; it unholds first.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.37}"
PKG_VERSION="${1:-}"
KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
LIST="/etc/apt/sources.list.d/kubernetes.list"
REPO="https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run with sudo." >&2
  exit 1
fi

echo "==> kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'MOD'
overlay
br_netfilter
MOD
modprobe overlay
modprobe br_netfilter

echo "==> sysctl"
# Docker already sets all three at runtime; writing them makes the node survive
# a boot where Docker starts late, which this host has done before.
cat > /etc/sysctl.d/99-kubernetes.conf <<'SYS'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null
for k in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables; do
  printf '    %-40s %s\n' "$k" "$(sysctl -n "$k")"
done

echo "==> apt repository (${K8S_MINOR})"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg >/dev/null
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "${REPO}Release.key" | gpg --dearmor --yes -o "$KEYRING"
echo "deb [signed-by=${KEYRING}] ${REPO} /" > "$LIST"
apt-get update -qq

if [ -z "$PKG_VERSION" ]; then
  echo
  echo "Candidates (pick one and rerun with it as the argument):"
  apt-cache madison kubeadm | head -5
  exit 0
fi

echo "==> installing ${PKG_VERSION}"
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get install -y \
  "kubelet=${PKG_VERSION}" "kubeadm=${PKG_VERSION}" "kubectl=${PKG_VERSION}"
apt-mark hold kubelet kubeadm kubectl

echo "==> crictl endpoint"
cat > /etc/crictl.yaml <<'CRI'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
CRI

systemctl enable --now kubelet >/dev/null 2>&1 || true

echo
kubeadm version -o short
kubectl version --client -o yaml | grep gitVersion | head -1
echo "OK - kubelet will crash-loop until kubeadm init runs. That is expected."
