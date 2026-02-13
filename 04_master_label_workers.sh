#!/bin/bash
set -e

# Run ONLY on cluster2-master after all workers have joined

export KUBECONFIG=/etc/kubernetes/admin.conf

WORKERS=(cluster2-worker-1 cluster2-worker-2 cluster2-worker-3 cluster2-worker-4)

for NODE in "${WORKERS[@]}"; do
    echo "Waiting for $NODE..."
    for i in $(seq 1 36); do
        STATUS=$(kubectl get node "$NODE" --no-headers 2>/dev/null | awk '{print $2}')
        [ "$STATUS" = "Ready" ] && echo "$NODE is Ready" && break
        echo "  $i/36 - ${STATUS:-NotFound}"
        sleep 10
    done
    kubectl label node "$NODE" kata-fc=true --overwrite
    kubectl label node "$NODE" openwhisk-role=invoker --overwrite
    kubectl label node "$NODE" node-role.kubernetes.io/worker=worker --overwrite
done

kubectl label node cluster2-master openwhisk-role=core --overwrite

echo ""
kubectl get nodes -o wide