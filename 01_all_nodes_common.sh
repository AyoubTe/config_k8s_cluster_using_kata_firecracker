#!/bin/bash
set -e

systemctl disable --now ufw 2>/dev/null || true
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# "Removing any leftover bad APT sources..."
rm -f /etc/apt/sources.list.d/firecracker*.list
rm -f /etc/apt/sources.list.d/kata*.list
grep -rl "firecracker-microvm.dev" /etc/apt/ | xargs rm -f 2>/dev/null || true

apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release socat conntrack

mkdir -p /etc/apt/keyrings

# "Installing Kubernetes repo key..."
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# "Installing Docker repo key..."
rm -f /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu focal stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confnew" containerd.io

# "Installing CNI plugins..."
CNI_VERSION="v1.3.0"
mkdir -p /opt/cni/bin
curl -fsSL --retry 3 \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
    -o /tmp/cni-plugins.tgz
tar -xf /tmp/cni-plugins.tgz -C /opt/cni/bin
rm /tmp/cni-plugins.tgz
ls /opt/cni/bin

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable --now containerd
systemctl enable kubelet

# Autoriser le verrouillage de la mémoire RAM
mkdir -p /etc/systemd/system/containerd.service.d/
cat <<EOF > /etc/systemd/system/containerd.service.d/override.conf
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=1048576
EOF

systemctl daemon-reload
systemctl restart containerd

echo "Common setup done on $(hostname)"