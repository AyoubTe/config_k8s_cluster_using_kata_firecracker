#!/bin/bash
set -e

# Run ONLY on cluster2-master

MASTER_IP="192.168.27.16"
POD_CIDR="10.245.0.0/16"

sort -u /etc/hosts -o /etc/hosts

cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: cluster2-master
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: 1.28.0
controlPlaneEndpoint: "${MASTER_IP}:6443"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs 2>&1 | tee /root/kubeadm-init.log

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

cat > /tmp/flannel-config-patch.json <<EOF
{"data": {"net-conf.json": "{\n  \"Network\": \"10.245.0.0/16\",\n  \"Backend\": {\n    \"Type\": \"vxlan\"\n  }\n}"}}
EOF

kubectl patch configmap kube-flannel-cfg -n kube-flannel --patch-file /tmp/flannel-config-patch.json 2>/dev/null || true

cat > /tmp/kata-fc-runtimeclass.yaml <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
handler: kata-fc
scheduling:
  nodeSelector:
    kata-fc: "true"
EOF

kubectl apply -f /tmp/kata-fc-runtimeclass.yaml

kubectl label node cluster2-master kata-fc=true --overwrite

echo ""
echo "============================================================"
echo "Master init complete."
echo "Run this on each worker node:"
echo "------------------------------------------------------------"
kubeadm token create --print-join-command
echo "============================================================"