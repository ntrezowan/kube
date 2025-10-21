--- Kubernetes Repository ---

### Core Cluster:
- containerd (v1.7.x latest stable)
- Kubernetes 1.33.x (kubeadm, kubelet, kubectl)
- Calico CNI (manifest-based, v3.28.x)
- metrics-server

### Tools:
- etcdctl (matching k8s etcd version)
- crictl (matching containerd version)
- kubesec (latest)
- krew + kubectl plugins (who-can, access-matrix)
- kube-bench (latest)

### Configuration:
- kubectl completion + alias (k=kubectl)
- Memory-optimized kubelet/containerd
- Untainted control-plane node


### Comparison Table
|                    | Create script | Reset script | Destroy script |
|--------------------|---------------|--------------|----------------|
| Kubernetes binaries| Installs      | Keeps        | Removes        |
| containerd         | Installs      | Keeps        | Removes        |
| Security tools     | Installs      | Keeps        | Removes        |
| Cluster state      | Creates       | Resets       | Removes        |
| Custom configs     | N/A           | Removes      | Removes        |
| Network changes    | Applies       | Resets       | Reverts        |
| Disk usage         | +2.5GB        | +2.5GB       | -2.5GB         |
| Reboot needed      | No            | No           | Recommended    |

