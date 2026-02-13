#!/bin/bash

# Run ONLY on cluster2-master

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "====== NODES ======"
kubectl get nodes -o wide

echo ""
echo "====== RUNTIMECLASS ======"
kubectl get runtimeclass

echo ""
echo "====== FLANNEL PODS ======"
kubectl get pods -n kube-flannel -o wide

echo ""
echo "====== OPENWHISK PODS ======"
kubectl get pods -n openwhisk -o wide

echo ""
echo "====== FLANNEL CONFIG ======"
kubectl get configmap kube-flannel-cfg -n kube-flannel \
    -o jsonpath='{.data.net-conf\.json}' | python3 -m json.tool 2>/dev/null || true

echo ""
echo "====== CONTAINERD KATA SHIM (run on each worker if needed) ======"
echo "  crictl info | grep -i kata"
echo "  kata-runtime --version"
echo "  firecracker --version"