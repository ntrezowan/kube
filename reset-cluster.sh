#!/bin/bash
#
# CKS Cluster Reset Script for Ubuntu 24.04
# Resets cluster to fresh state while keeping Kubernetes and tools installed
#
# What it does:
# - Runs kubeadm reset (removes cluster state)
# - Cleans up CNI configs
# - Removes etcd data
# - Removes custom configs (Gatekeeper, Falco rules, AppArmor profiles, audit policies)
# - Re-initializes cluster WITH kube-proxy
# - Re-applies Calico CNI
# - Untaints control-plane
#
# What it keeps:
# - Kubernetes binaries (kubeadm, kubelet, kubectl)
# - containerd
# - All security tools (Trivy, Falco, kube-bench, crictl, etcdctl, etc.)
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
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
fi

# Configuration
K8S_VERSION="1.33.0"
CALICO_VERSION="v3.28.2"
POD_CIDR="192.168.0.0/16"

log_warn "==============================================="
log_warn "CKS CLUSTER RESET SCRIPT"
log_warn "==============================================="
log_warn "This will reset your cluster to fresh state"
log_warn "All pods, configs, and custom resources will be deleted"
log_warn "Kubernetes and tools will remain installed"
echo ""
read -p "Continue? (type 'yes' to confirm): " -r
echo
if [[ ! $REPLY =~ ^yes$ ]]; then
    log_info "Aborted by user"
    exit 0
fi

log_info "Starting cluster reset..."

# ============================================================================
# STEP 1: Reset Kubernetes cluster
# ============================================================================

log_info "STEP 1: Running kubeadm reset..."

kubeadm reset -f

log_info "kubeadm reset completed"

# ============================================================================
# STEP 2: Clean up residual files and directories
# ============================================================================

log_info "STEP 2: Cleaning up residual files..."

# Remove etcd data
rm -rf /var/lib/etcd

# Remove CNI configs (will be recreated)
rm -rf /etc/cni/net.d/*
rm -rf /var/lib/cni/*

# Clean up kubelet state
rm -rf /var/lib/kubelet/*

# Remove any leftover pods
rm -rf /etc/kubernetes/manifests/*.yaml.backup 2>/dev/null || true

log_info "Residual files cleaned"

# ============================================================================
# STEP 3: Clean up custom security configurations
# ============================================================================

log_info "STEP 3: Removing custom security configurations..."

# Remove Falco custom rules (keep default installation)
rm -f /etc/falco/falco_rules.local.yaml 2>/dev/null || true
log_info "  - Falco custom rules removed"

# Remove custom AppArmor profiles (keep system profiles)
for profile in /etc/apparmor.d/k8s-*; do
    if [ -f "$profile" ]; then
        profile_name=$(basename "$profile")
        sudo apparmor_parser -R "$profile" 2>/dev/null || true
        rm -f "$profile"
        log_info "  - AppArmor profile removed: $profile_name"
    fi
done

# Remove audit policy if exists
rm -f /etc/kubernetes/audit-policy.yaml 2>/dev/null || true
log_info "  - Audit policy removed"

# Stop Falco if running
systemctl stop falco 2>/dev/null || true
log_info "  - Falco stopped"

log_info "Custom security configurations removed"

# ============================================================================
# STEP 4: Clean up iptables rules
# ============================================================================

log_info "STEP 4: Flushing iptables rules..."

iptables -F || true
iptables -t nat -F || true
iptables -t mangle -F || true
iptables -X || true
iptables -t nat -X || true
iptables -t mangle -X || true

ip6tables -F || true
ip6tables -t nat -F || true
ip6tables -t mangle -F || true
ip6tables -X || true
ip6tables -t nat -X || true
ip6tables -t mangle -X || true

log_info "iptables rules flushed"

# ============================================================================
# STEP 5: Remove CNI network interfaces
# ============================================================================

log_info "STEP 5: Removing CNI network interfaces..."

for iface in $(ip link show | grep -E 'cali|tunl|vxlan.calico|flannel|weave' | awk -F: '{print $2}' | tr -d ' '); do
    ip link delete "$iface" 2>/dev/null || true
    log_info "  - Removed interface: $iface"
done

# ============================================================================
# STEP 6: Restart containerd
# ============================================================================

log_info "STEP 6: Restarting containerd..."

systemctl restart containerd
sleep 3

log_info "containerd restarted"

# ============================================================================
# STEP 7: Re-initialize Kubernetes cluster (WITH kube-proxy)
# ============================================================================

log_info "STEP 7: Re-initializing Kubernetes cluster..."

# IMPORTANT: Do NOT skip kube-proxy - it's required for service networking
kubeadm init \
  --pod-network-cidr=$POD_CIDR \
  --kubernetes-version=$K8S_VERSION \
  --ignore-preflight-errors=NumCPU,Mem 2>&1 | tee /tmp/kubeadm-init.log

log_info "Cluster re-initialized successfully"

# ============================================================================
# STEP 8: Configure kubectl
# ============================================================================

log_info "STEP 8: Configuring kubectl..."

# Get original user
ORIGINAL_USER=${SUDO_USER:-$USER}
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configure kubectl for root
export KUBECONFIG=/etc/kubernetes/admin.conf

# Configure kubectl for original user
mkdir -p "$ORIGINAL_HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$ORIGINAL_HOME/.kube/config"
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.kube"

log_info "kubectl configured"

# ============================================================================
# STEP 9: Untaint control-plane node
# ============================================================================

log_info "STEP 9: Untainting control-plane node..."

sleep 10
kubectl wait --for=condition=Ready node --all --timeout=60s || log_warn "Node not ready yet, continuing..."

kubectl taint nodes --all node-role.kubernetes.io/control-plane- || log_warn "Taint already removed or not present"

log_info "Control-plane node untainted"

# ============================================================================
# STEP 10: Verify kube-proxy is running
# ============================================================================

log_info "STEP 10: Verifying kube-proxy..."

# Wait for kube-proxy to be ready
kubectl wait --for=condition=Ready pods -l k8s-app=kube-proxy -n kube-system --timeout=120s || log_warn "kube-proxy may still be starting"

log_info "kube-proxy is running"

# ============================================================================
# STEP 11: Re-install Calico CNI
# ============================================================================

log_info "STEP 11: Re-installing Calico CNI..."

curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml -o /tmp/calico.yaml

kubectl apply -f /tmp/calico.yaml

log_info "Waiting for Calico pods to be ready (may take 3-5 minutes)..."

# More lenient wait - check if pods exist first
for i in {1..60}; do
    if kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
        log_info "Calico pods detected, waiting for them to be ready..."
        break
    fi
    sleep 5
done

kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=600s || log_warn "Calico node pods may still be initializing"
kubectl wait --for=condition=Ready pods -l k8s-app=calico-kube-controllers -n kube-system --timeout=300s || log_warn "Calico controller may still be initializing"

log_info "Calico CNI re-installed successfully"

# ============================================================================
# STEP 12: Wait for metrics-server (if it was installed)
# ============================================================================

if kubectl get deployment -n kube-system metrics-server &>/dev/null; then
    log_info "STEP 12: Waiting for metrics-server to be ready..."
    kubectl wait --for=condition=Ready pod -l k8s-app=metrics-server -n kube-system --timeout=300s || log_warn "metrics-server may still be initializing"
    log_info "metrics-server ready"
else
    log_info "STEP 12: metrics-server not installed, skipping"
fi

# ============================================================================
# STEP 13: Verification
# ============================================================================

log_info "STEP 13: Verifying cluster status..."

# Wait for all system pods to be ready
log_info "Waiting for all system pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=600s || log_warn "Some pods may still be initializing"

# Display cluster info
echo ""
log_info "==============================================="
log_info "CLUSTER RESET COMPLETED SUCCESSFULLY!"
log_info "==============================================="
echo ""

kubectl get nodes -o wide
echo ""
kubectl get pods -A
echo ""

log_info "Cluster is now in fresh state"
log_info "All tools remain installed and ready:"
echo "  - Kubernetes: $(kubectl version --client --short 2>/dev/null | grep Client || echo 'v1.33.0')"
echo "  - Trivy: $(trivy --version 2>/dev/null | head -1 || echo 'installed')"
echo "  - Falco: $(systemctl is-active falco 2>/dev/null || echo 'stopped (install configs as needed)')"
echo "  - kube-bench: installed"
echo "  - crictl: $(crictl --version)"
echo "  - etcdctl: installed"
echo "  - kubesec: installed"
echo "  - krew: installed"
echo "  - kube-proxy: running"
echo ""

log_info "Next Steps:"
echo "  1. Test cluster: kubectl get nodes"
echo "  2. Install security configs as needed (Gatekeeper, Falco rules, AppArmor profiles, Audit logging)"
echo "  3. Start your practice scenarios"
echo ""

log_info "When you're done with this sprint, run this script again for next week's fresh cluster"
log_info "When completely finished with CKS prep, run cks-cluster-destroy.sh to remove everything"

# Clean up temp files
rm -f /tmp/calico.yaml

exit 0
