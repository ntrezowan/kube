#!/bin/bash
#
# CKS Cluster Destruction Script for Ubuntu 24.04
# Removes ALL Kubernetes components and returns system to vanilla state
# WARNING: This will completely remove your cluster and all data!
#

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

log_warn "==============================================="
log_warn "CKS CLUSTER DESTRUCTION SCRIPT"
log_warn "==============================================="
log_warn "This will COMPLETELY REMOVE your Kubernetes cluster"
log_warn "and all related configurations!"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " -r
echo
if [[ ! $REPLY =~ ^yes$ ]]; then
    log_info "Aborted by user"
    exit 0
fi

log_info "Starting cluster destruction..."

# ============================================================================
# STEP 1: Reset Kubernetes cluster
# ============================================================================

log_info "STEP 1: Resetting Kubernetes cluster..."

if command -v kubeadm &> /dev/null; then
    kubeadm reset -f || log_warn "kubeadm reset failed or already reset"
else
    log_warn "kubeadm not found, skipping reset"
fi

# ============================================================================
# STEP 2: Stop and disable services
# ============================================================================

log_info "STEP 2: Stopping and disabling services..."

systemctl stop kubelet || true
systemctl disable kubelet || true
systemctl stop containerd || true
systemctl disable containerd || true

# ============================================================================
# STEP 3: Remove Kubernetes packages
# ============================================================================

log_info "STEP 3: Removing Kubernetes packages..."

apt-mark unhold kubelet kubeadm kubectl || true
apt-get purge -y -qq kubelet kubeadm kubectl || true
apt-get autoremove -y -qq || true

# ============================================================================
# STEP 4: Remove containerd
# ============================================================================

log_info "STEP 4: Removing containerd..."

apt-get purge -y -qq containerd.io || true
apt-get autoremove -y -qq || true

# ============================================================================
# STEP 5: Remove binaries
# ============================================================================

log_info "STEP 5: Removing installed binaries..."

rm -f /usr/local/bin/crictl
rm -f /usr/local/bin/etcdctl
rm -f /usr/local/bin/kubesec
rm -f /usr/local/bin/kube-bench

# ============================================================================
# STEP 6: Remove configuration directories
# ============================================================================

log_info "STEP 6: Removing configuration directories..."

# Kubernetes directories
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/systemd/system/kubelet.service.d

# Container runtime directories
rm -rf /etc/containerd
rm -rf /var/lib/containerd
rm -rf /run/containerd
rm -rf /etc/crictl.yaml

# CNI directories
rm -rf /etc/cni
rm -rf /opt/cni
rm -rf /var/lib/cni

# kubectl config
rm -rf "$ORIGINAL_HOME/.kube"

# krew
rm -rf "$ORIGINAL_HOME/.krew"

# ============================================================================
# STEP 7: Clean up iptables rules
# ============================================================================

log_info "STEP 7: Cleaning up iptables rules..."

# Flush all chains
iptables -F || true
iptables -t nat -F || true
iptables -t mangle -F || true
iptables -X || true

# Delete custom chains created by Kubernetes/Calico
iptables -t nat -X || true
iptables -t mangle -X || true

# Reset ip6tables as well
ip6tables -F || true
ip6tables -t nat -F || true
ip6tables -t mangle -F || true
ip6tables -X || true
ip6tables -t nat -X || true
ip6tables -t mangle -X || true

log_info "iptables rules flushed"

# ============================================================================
# STEP 8: Remove virtual network interfaces
# ============================================================================

log_info "STEP 8: Removing virtual network interfaces..."

# Remove CNI interfaces
for iface in $(ip link show | grep -E 'cali|tunl|vxlan.calico|flannel|weave' | awk -F: '{print $2}' | tr -d ' '); do
    ip link delete "$iface" 2>/dev/null || true
    log_info "Removed interface: $iface"
done

# Remove docker bridge (if exists)
ip link delete docker0 2>/dev/null || true

# ============================================================================
# STEP 9: Remove kernel modules configuration
# ============================================================================

log_info "STEP 9: Removing kernel modules configuration..."

rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/modules-load.d/containerd.conf

# Unload modules (best effort)
modprobe -r overlay 2>/dev/null || true
modprobe -r br_netfilter 2>/dev/null || true

# ============================================================================
# STEP 10: Remove sysctl configuration
# ============================================================================

log_info "STEP 10: Removing sysctl configuration..."

rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/sysctl.d/99-kubernetes-cri.conf

# Reset sysctl to defaults
sysctl --system > /dev/null 2>&1 || true

# ============================================================================
# STEP 11: Re-enable swap
# ============================================================================

log_info "STEP 11: Re-enabling swap..."

# Uncomment swap entries in fstab
sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab 2>/dev/null || true

# If swap file exists, enable it
if [ -f /swap.img ]; then
    swapon /swap.img 2>/dev/null || log_warn "Could not enable swap (may need reboot)"
elif [ -f /swapfile ]; then
    swapon /swapfile 2>/dev/null || log_warn "Could not enable swap (may need reboot)"
fi

# ============================================================================
# STEP 12: Remove APT repositories
# ============================================================================

log_info "STEP 12: Removing APT repositories..."

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/keyrings/docker.asc

apt-get update -qq || true

# ============================================================================
# STEP 13: Clean up bash configurations
# ============================================================================

log_info "STEP 13: Cleaning up bash configurations..."

# Remove kubectl configurations from root
sed -i '/kubectl completion bash/d' /root/.bashrc 2>/dev/null || true
sed -i '/alias k=kubectl/d' /root/.bashrc 2>/dev/null || true
sed -i '/complete -o default -F __start_kubectl k/d' /root/.bashrc 2>/dev/null || true
sed -i '/KUBECONFIG/d' /root/.bashrc 2>/dev/null || true

# Remove kubectl configurations from original user
sed -i '/kubectl completion bash/d' "$ORIGINAL_HOME/.bashrc" 2>/dev/null || true
sed -i '/alias k=kubectl/d' "$ORIGINAL_HOME/.bashrc" 2>/dev/null || true
sed -i '/complete -o default -F __start_kubectl k/d' "$ORIGINAL_HOME/.bashrc" 2>/dev/null || true
sed -i '/KUBECONFIG/d' "$ORIGINAL_HOME/.bashrc" 2>/dev/null || true
sed -i '/krew/d' "$ORIGINAL_HOME/.bashrc" 2>/dev/null || true

# ============================================================================
# STEP 14: Clean up systemd
# ============================================================================

log_info "STEP 14: Cleaning up systemd..."

systemctl daemon-reload
systemctl reset-failed

# ============================================================================
# STEP 15: Clean up temporary files
# ============================================================================

log_info "STEP 15: Cleaning up temporary files..."

rm -f /tmp/kubeadm-init.log
rm -f /tmp/calico.yaml
rm -f /tmp/cluster-info.txt

# ============================================================================
# STEP 16: Final cleanup
# ============================================================================

log_info "STEP 16: Running final cleanup..."

# Remove any remaining container images/data
rm -rf /var/lib/docker 2>/dev/null || true

# Clean apt cache
apt-get clean

log_info "==============================================="
log_info "CLUSTER DESTRUCTION COMPLETED!"
log_info "==============================================="
echo ""
log_info "Summary:"
echo "  ✓ Kubernetes cluster removed"
echo "  ✓ containerd removed"
echo "  ✓ All binaries removed"
echo "  ✓ Configuration directories cleaned"
echo "  ✓ Network interfaces removed"
echo "  ✓ iptables rules flushed"
echo "  ✓ Kernel modules configuration removed"
echo "  ✓ Swap re-enabled"
echo "  ✓ APT repositories removed"
echo "  ✓ Bash configurations cleaned"
echo ""
log_warn "Remaining artifacts (normal):"
echo "  - Some log entries in /var/log"
echo "  - APT package cache"
echo "  - Some systemd journal entries"
echo ""
log_info "System Status: ~99% returned to vanilla Ubuntu 24.04"
echo ""
log_warn "Recommended: Reboot the system for complete cleanup"
read -p "Reboot now? (y/n): " -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    log_info "Reboot skipped. You can reboot manually later."
fi

exit 0

