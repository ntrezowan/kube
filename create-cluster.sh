#!/bin/bash
#
# CKS Cluster Setup Script for Ubuntu 24.04
#
# Kubernetes Version: 1.33.x
# Container Runtime: containerd
# CNI: Calico (manifest-based)
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration Variables
K8S_VERSION="1.33.0"
CALICO_VERSION="v3.28.2"
CRICTL_VERSION="v1.31.1"
KUBE_BENCH_VERSION="0.8.0"
POD_CIDR="192.168.0.0/16"

# Logging functions
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

# Get the original user who invoked sudo
ORIGINAL_USER=${SUDO_USER:-$USER}
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

log_info "Starting CKS cluster setup for user: $ORIGINAL_USER"
log_info "Kubernetes Version: $K8S_VERSION"
log_info "Target: Memory-optimized single-node cluster"

# ============================================================================
# PRE-CHECK: Detect existing installation
# ============================================================================

CLUSTER_EXISTS=false
if systemctl is-active --quiet kubelet && [ -f /etc/kubernetes/admin.conf ]; then
    log_warn "Existing Kubernetes cluster detected!"
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; then
        CLUSTER_EXISTS=true
        log_warn "Cluster is running and accessible"
        echo ""
        kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes
        echo ""
        read -p "Skip cluster initialization and only install missing tools? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping to tool installation..."
            SKIP_CLUSTER_INIT=true
        else
            log_error "Please run cks-cluster-destroy.sh first, then retry this script"
        fi
    fi
fi

# ============================================================================
# STEP 1: System Preparation
# ============================================================================

log_info "STEP 1: Preparing system..."

# Disable swap (required for kubelet)
log_info "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load required kernel modules
log_info "Loading kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure sysctl for Kubernetes networking
log_info "Configuring sysctl parameters..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null

# Update system packages
log_info "Updating system packages..."
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg socat conntrack

# ============================================================================
# STEP 2: Install containerd
# ============================================================================

if ! command -v containerd &> /dev/null; then
    log_info "STEP 2: Installing containerd..."

    # Install containerd from Docker repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq containerd.io
else
    log_info "STEP 2: containerd already installed, configuring..."
fi

# Configure containerd for Kubernetes
log_info "Configuring containerd..."
mkdir -p /etc/containerd

# Generate default config
sh -c "containerd config default > /etc/containerd/config.toml"

# Enable systemd cgroup driver (required for kubelet)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Verify config is valid before restarting
if ! containerd config dump > /dev/null 2>&1; then
    log_error "containerd config validation failed. Check /etc/containerd/config.toml"
fi

# Reload systemd and restart containerd
systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd

# Verify containerd is running
if ! systemctl is-active --quiet containerd; then
    log_error "containerd failed to start. Check: sudo journalctl -u containerd -n 50"
fi

log_info "containerd installed and configured successfully"

# ============================================================================
# STEP 3: Install Kubernetes components
# ============================================================================

if ! command -v kubeadm &> /dev/null; then
    log_info "STEP 3: Installing Kubernetes components (v$K8S_VERSION)..."

    # Add Kubernetes APT repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq

    # Install specific version
    KUBE_VERSION="${K8S_VERSION}-1.1"
    apt-get install -y -qq kubelet=${KUBE_VERSION} kubeadm=${KUBE_VERSION} kubectl=${KUBE_VERSION}

    # Hold packages to prevent accidental upgrades
    apt-mark hold kubelet kubeadm kubectl

    log_info "Kubernetes components installed successfully"
else
    log_info "STEP 3: Kubernetes components already installed"
fi

# ============================================================================
# STEP 4: Configure kubelet for memory optimization
# ============================================================================

log_info "STEP 4: Configuring kubelet for t3.medium..."

# Create kubelet configuration directory
mkdir -p /etc/systemd/system/kubelet.service.d

# Add resource reservation flags
cat <<EOF > /etc/systemd/system/kubelet.service.d/20-resource-optimization.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--system-reserved=cpu=200m,memory=512Mi --kube-reserved=cpu=200m,memory=768Mi --eviction-hard=memory.available<256Mi --max-pods=50"
EOF

systemctl daemon-reload

log_info "kubelet configured for memory optimization"

# ============================================================================
# STEP 5: Initialize Kubernetes cluster (if not exists)
# ============================================================================

if [ "${SKIP_CLUSTER_INIT:-false}" = "false" ]; then
    log_info "STEP 5: Initializing Kubernetes cluster..."

    # Initialize cluster with kubeadm
    kubeadm init \
      --pod-network-cidr=$POD_CIDR \
      --kubernetes-version=$K8S_VERSION \
      --ignore-preflight-errors=NumCPU,Mem 2>&1 | tee /tmp/kubeadm-init.log

    log_info "Cluster initialized successfully"

    # Configure kubectl for root
    export KUBECONFIG=/etc/kubernetes/admin.conf
    echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc

    # Configure kubectl for original user
    mkdir -p "$ORIGINAL_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$ORIGINAL_HOME/.kube/config"
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.kube"

    log_info "kubectl configured for $ORIGINAL_USER"
else
    log_info "STEP 5: Skipping cluster initialization (already exists)"
    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    # Ensure kubectl is configured for original user
    mkdir -p "$ORIGINAL_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$ORIGINAL_HOME/.kube/config"
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.kube"
fi

# ============================================================================
# STEP 6: Untaint control-plane node (single-node cluster)
# ============================================================================

if [ "${SKIP_CLUSTER_INIT:-false}" = "false" ]; then
    log_info "STEP 6: Untainting control-plane node..."

    # Wait for node to be ready
    sleep 10
    kubectl wait --for=condition=Ready node --all --timeout=60s || log_warn "Node not ready yet, continuing..."

    # Remove taint to allow pod scheduling on control-plane
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || log_warn "Taint already removed or not present"

    log_info "Control-plane node untainted"
else
    log_info "STEP 6: Skipping untaint (cluster already configured)"
fi

# ============================================================================
# STEP 7: Install Calico CNI (if not exists)
# ============================================================================

if ! kubectl get daemonset -n kube-system calico-node &>/dev/null; then
    log_info "STEP 7: Installing Calico CNI ($CALICO_VERSION)..."

    # Download Calico manifest
    curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml -o /tmp/calico.yaml

    # Apply Calico
    kubectl apply -f /tmp/calico.yaml

    # Wait for Calico pods to be ready
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

    log_info "Calico CNI installed successfully"
else
    log_info "STEP 7: Calico CNI already installed"
fi

# ============================================================================
# STEP 8: Install metrics-server (if not exists)
# ============================================================================

if ! kubectl get deployment -n kube-system metrics-server &>/dev/null; then
    log_info "STEP 8: Installing metrics-server..."

    # Download and apply metrics-server manifest
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    # Patch metrics-server for insecure TLS (required for single-node clusters)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

    log_info "metrics-server installed (may take 1-2 minutes to be ready)"
else
    log_info "STEP 8: metrics-server already installed"
fi

# ============================================================================
# STEP 9: Install crictl
# ============================================================================

if ! command -v crictl &> /dev/null; then
    log_info "STEP 9: Installing crictl ($CRICTL_VERSION)..."

    wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz
    tar zxf crictl-$CRICTL_VERSION-linux-amd64.tar.gz -C /usr/local/bin
    rm -f crictl-$CRICTL_VERSION-linux-amd64.tar.gz

    # Configure crictl to use containerd
    cat <<EOF > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

    log_info "crictl installed successfully"
else
    log_info "STEP 9: crictl already installed"
fi

# ============================================================================
# STEP 10: Install etcdctl
# ============================================================================

if ! command -v etcdctl &> /dev/null; then
    log_info "STEP 10: Installing etcdctl..."

    # Get etcd version from running pod
    ETCD_VERSION=$(kubectl get pod -n kube-system -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "")

    if [[ -z "$ETCD_VERSION" ]]; then
        log_warn "Could not detect etcd version, using v3.5.15"
        ETCD_VERSION="v3.5.15"
    fi

    log_info "Installing etcdctl version: $ETCD_VERSION"

    wget -q https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz
    tar zxf etcd-$ETCD_VERSION-linux-amd64.tar.gz
    mv etcd-$ETCD_VERSION-linux-amd64/etcdctl /usr/local/bin/
    rm -rf etcd-$ETCD_VERSION-linux-amd64*

    log_info "etcdctl installed successfully"
else
    log_info "STEP 10: etcdctl already installed"
fi

# ============================================================================
# STEP 11: Install kubesec
# ============================================================================

if ! command -v kubesec &> /dev/null; then
    log_info "STEP 11: Installing kubesec..."

    wget -q https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
    tar zxf kubesec_linux_amd64.tar.gz
    mv kubesec /usr/local/bin/
    rm -f kubesec_linux_amd64.tar.gz

    log_info "kubesec installed successfully"
else
    log_info "STEP 11: kubesec already installed"
fi

# ============================================================================
# STEP 12: Install kube-bench
# ============================================================================

if ! command -v kube-bench &> /dev/null; then
    log_info "STEP 12: Installing kube-bench (v$KUBE_BENCH_VERSION)..."

    wget -q https://github.com/aquasecurity/kube-bench/releases/download/v$KUBE_BENCH_VERSION/kube-bench_${KUBE_BENCH_VERSION}_linux_amd64.tar.gz
    tar zxf kube-bench_${KUBE_BENCH_VERSION}_linux_amd64.tar.gz
    mv kube-bench /usr/local/bin/
    rm -f kube-bench_${KUBE_BENCH_VERSION}_linux_amd64.tar.gz

    log_info "kube-bench installed successfully"
else
    log_info "STEP 12: kube-bench already installed"
fi

# ============================================================================
# STEP 13: Install krew and kubectl plugins
# ============================================================================

if [ ! -d "$ORIGINAL_HOME/.krew" ]; then
    log_info "STEP 13: Installing krew and kubectl plugins..."

    # Install krew for original user
    su - "$ORIGINAL_USER" <<'KREWEOF'
set -x
cd "$(mktemp -d)"
OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
KREW="krew-${OS}_${ARCH}"
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz"
tar zxf "${KREW}.tar.gz"
./"${KREW}" install krew
KREWEOF

    # Add krew to PATH for original user
    if ! grep -q 'krew' "$ORIGINAL_HOME/.bashrc"; then
        echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> "$ORIGINAL_HOME/.bashrc"
    fi

    # Install useful plugins
    su - "$ORIGINAL_USER" <<'PLUGINEOF'
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
kubectl krew install who-can
kubectl krew install access-matrix
PLUGINEOF

    log_info "krew and plugins installed successfully"
else
    log_info "STEP 13: krew already installed"
fi

# ============================================================================
# STEP 14: Configure kubectl completion and aliases
# ============================================================================

log_info "STEP 14: Configuring kubectl completion and aliases..."

# For root
if ! grep -q 'kubectl completion bash' /root/.bashrc; then
    echo 'source <(kubectl completion bash)' >> /root/.bashrc
    echo 'alias k=kubectl' >> /root/.bashrc
    echo 'complete -o default -F __start_kubectl k' >> /root/.bashrc
fi

# For original user
if ! grep -q 'kubectl completion bash' "$ORIGINAL_HOME/.bashrc"; then
    echo 'source <(kubectl completion bash)' >> "$ORIGINAL_HOME/.bashrc"
    echo 'alias k=kubectl' >> "$ORIGINAL_HOME/.bashrc"
    echo 'complete -o default -F __start_kubectl k' >> "$ORIGINAL_HOME/.bashrc"
fi

log_info "kubectl completion and aliases configured"

# ============================================================================
# STEP 15: Verification
# ============================================================================

log_info "STEP 15: Verifying cluster status..."

# Wait for all system pods to be ready
log_info "Waiting for all system pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=600s || log_warn "Some pods may still be initializing"

# Display cluster info
echo ""
log_info "==============================================="
log_info "CKS CLUSTER SETUP COMPLETED SUCCESSFULLY!"
log_info "==============================================="
echo ""

kubectl get nodes -o wide
echo ""
kubectl get pods -A
echo ""

log_info "Installed Tools:"
echo "  - Kubernetes: $(kubectl version --client --short 2>/dev/null | grep Client || echo $K8S_VERSION)"
echo "  - containerd: $(containerd --version | head -n1)"
echo "  - crictl: $(crictl --version)"
echo "  - etcdctl: $(etcdctl version | head -n1 2>/dev/null || echo 'installed')"
echo "  - kubesec: $(kubesec version 2>/dev/null || echo 'installed')"
echo "  - kube-bench: v$KUBE_BENCH_VERSION"
echo "  - krew: installed"
echo ""

log_info "kubectl aliases configured:"
echo "  - k=kubectl (with bash completion)"
echo ""

log_info "Cluster Configuration:"
echo "  - Single-node cluster (control-plane untainted)"
echo "  - CNI: Calico $CALICO_VERSION"
echo "  - Pod CIDR: $POD_CIDR"
echo "  - Memory-optimized for t3.medium"
echo ""

log_info "Next Steps:"
echo "  1. Logout and login again (or run: source ~/.bashrc)"
echo "  2. Test cluster: kubectl get nodes"
echo "  3. Test metrics: kubectl top nodes (wait 2-3 minutes if not ready)"
echo "  4. Refer to separate docs for: Audit Logging, Trivy, Falco, AppArmor, Gatekeeper"
echo ""

log_warn "IMPORTANT: Monitor memory usage with 'kubectl top nodes' - t3.medium is at minimum spec"

# Save cluster info for reference
kubectl cluster-info > /tmp/cluster-info.txt 2>/dev/null || true
log_info "Cluster info saved to: /tmp/cluster-info.txt"

exit 0
