#!/bin/bash
set -e

# Run on EACH worker node
# Usage: bash 03_workers_join.sh kubeadm join 192.168.27.16:6443 --token X --discovery-token-ca-cert-hash sha256:X

sort -u /etc/hosts -o /etc/hosts

if [ -z "$*" ]; then
    echo "ERROR: Pass the full kubeadm join command as argument"
    echo "Usage: bash 03_workers_join.sh kubeadm join 192.168.27.16:6443 --token X --discovery-token-ca-cert-hash sha256:X"
    exit 1
fi

"$@" --cri-socket unix:///run/containerd/containerd.sock

echo "Worker $(hostname) joined. Now run 04_master_label_workers.sh on the master."