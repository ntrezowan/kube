Core Cluster:

containerd (v1.7.x latest stable)
Kubernetes 1.33.x (kubeadm, kubelet, kubectl)
Calico CNI (manifest-based, v3.28.x)
metrics-server

CKS Security Tools:

etcdctl (matching k8s etcd version)
crictl (matching containerd version)
kubesec (latest)
krew + kubectl plugins (who-can, access-matrix)
kube-bench (latest)

Configuration:

kubectl completion + alias (k=kubectl)
Memory-optimized kubelet/containerd
Untainted control-plane node


Comparison Table
AspectSetup ScriptReset ScriptDestroy ScriptRuntime8-12 min3-5 min2-3 minKubernetes binariesInstallsKeepsRemovescontainerdInstallsKeepsRemovesSecurity toolsInstallsKeepsRemovesCluster stateCreatesResetsRemovesCustom configsN/ARemovesRemovesNetwork changesAppliesResetsRevertsDisk usage+2.5GBSame-2.5GBReboot neededNoNoRecommendedFrequencyOnceWeeklyOnce (end)
