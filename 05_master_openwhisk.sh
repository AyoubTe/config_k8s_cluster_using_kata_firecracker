#!/bin/bash
set -e

export KUBECONFIG=/etc/kubernetes/admin.conf

if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# "====== Removing control-plane taint so core pods can schedule on master ======"
kubectl taint node cluster2-master node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
kubectl taint node cluster2-master node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true

# "====== Uninstalling any existing OpenWhisk release ======"
helm uninstall owdev -n openwhisk 2>/dev/null || true
kubectl delete pods -n openwhisk --all --force --grace-period=0 2>/dev/null || true
sleep 10

# "====== Deleting old PVCs (storageClassName is immutable - must recreate) ======"
kubectl delete pvc --all -n openwhisk 2>/dev/null || true
sleep 5

# "====== Creating StorageClass (default) ======"
cat <<'SCEOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
SCEOF

# "====== Creating local directories on master ======"
mkdir -p /mnt/pv-couchdb /mnt/pv-kafka /mnt/pv-zookeeper-data /mnt/pv-zookeeper-log /mnt/pv-redis /mnt/pv-alarmprovider
chmod 777 /mnt/pv-couchdb /mnt/pv-kafka /mnt/pv-zookeeper-data /mnt/pv-zookeeper-log /mnt/pv-redis /mnt/pv-alarmprovider

# "====== Deleting old PVs if they exist ======"
kubectl delete pv pv-couchdb pv-kafka pv-zookeeper-data pv-zookeeper-log pv-redis 2>/dev/null || true
sleep 3

# "====== Force-removing any PVs stuck in Terminating ======"
for PV in $(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch pv "$PV" -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done
kubectl delete pv pv-couchdb pv-kafka pv-zookeeper-data pv-zookeeper-log pv-redis pv-alarmprovider 2>/dev/null || true
sleep 5

# "====== Clearing PV data directories ======"
rm -rf /mnt/pv-couchdb/* /mnt/pv-kafka/* /mnt/pv-zookeeper-data/* /mnt/pv-zookeeper-log/* /mnt/pv-redis/* /mnt/pv-alarmprovider/*

echo "====== Creating PersistentVolumes (sizes match OpenWhisk Helm chart defaults) ======"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-couchdb
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-couchdb
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-kafka
spec:
  capacity:
    storage: 512Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-zookeeper-data
spec:
  capacity:
    storage: 256Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-zookeeper-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-zookeeper-log
spec:
  capacity:
    storage: 256Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-zookeeper-log
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-redis
spec:
  capacity:
    storage: 256Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-redis
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-alarmprovider
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/pv-alarmprovider
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - cluster2-master
EOF

kubectl get pv

# "====== Installing OpenWhisk via Helm ======"
helm repo add openwhisk https://openwhisk.apache.org/charts 2>/dev/null || true
helm repo update
kubectl create namespace openwhisk 2>/dev/null || true

cat > /tmp/openwhisk-values.yaml <<EOF
whisk:
  ingress:
    type: NodePort
    apiHostName: 192.168.27.16
    apiHostPort: 31001

invoker:
  containerFactory:
    impl: "kubernetes"
  jvmHeapMB: "512"

controller:
  replicaCount: 1
  jvmHeapMB: "1024"

db:
  external: false
  wipeAndInit: true
  storageClass: local-storage
  auth:
    username: "whisk_admin"
    password: "some_passw0rd"

kafka:
  replicaCount: 1
  persistence:
    storageClass: local-storage

zookeeper:
  replicaCount: 1
  persistence:
    storageClass: local-storage

redis:
  persistence:
    storageClass: local-storage

nginx:
  httpsNodePort: 31001

affinity:
  nodeAffinity:
    invokerRequiredDuringScheduling:
      key: openwhisk-role
      value: invoker
    coreRequiredDuringScheduling:
      key: openwhisk-role
      value: core
EOF

helm install owdev openwhisk/openwhisk \
    --namespace openwhisk \
    --values /tmp/openwhisk-values.yaml \
    --timeout 20m \
    --wait || true

# "====== Patching any PVCs missing storageClassName ======"
for PVC in $(kubectl get pvc -n openwhisk -o jsonpath='{.items[*].metadata.name}'); do
    SC=$(kubectl get pvc "$PVC" -n openwhisk -o jsonpath='{.spec.storageClassName}')
    if [ -z "$SC" ] || [ "$SC" = "null" ]; then
        kubectl patch pvc "$PVC" -n openwhisk \
            --type=merge \
            -p='{"spec":{"storageClassName":"local-storage"}}' 2>/dev/null || true
        echo "Patched $PVC"
    fi
done

echo ""
kubectl get pv
kubectl get pvc -n openwhisk
kubectl get pods -n openwhisk -o wide

echo ""
echo "====== Increasing invoker timeout for Kata (180s instead of 60s) ======"
kubectl patch statefulset owdev-invoker -n openwhisk --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "INVOKER_OPTS",
      "value": " -Dkubernetes.master=https://$KUBERNETES_SERVICE_HOST -Dwhisk.spi.ContainerFactoryProvider=org.apache.openwhisk.core.containerpool.kubernetes.KubernetesContainerFactoryProvider -Dwhisk.kubernetes.timeouts.run=180s -Dwhisk.kubernetes.timeouts.logs=180s"
    }
  }
]' 2>/dev/null || {
    echo "INVOKER_OPTS already exists, updating..."
    kubectl patch statefulset owdev-invoker -n openwhisk --type=json -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/env",
        "value": [
          {"name": "PORT", "value": "8080"},
          {"name": "WHISK_API_HOST_PROTO", "value": "https"},
          {"name": "WHISK_API_HOST_PORT", "value": "443"},
          {"name": "WHISK_API_HOST_NAME", "valueFrom": {"fieldRef": {"fieldPath": "status.hostIP"}}},
          {"name": "INVOKER_CONTAINER_NETWORK", "value": "bridge"},
          {"name": "CONFIG_whisk_containerFactory_containerArgs_network", "value": "bridge"},
          {"name": "INVOKER_CONTAINER_DNS", "value": ""},
          {"name": "INVOKER_USE_RUNC", "value": "false"},
          {"name": "DOCKER_IMAGE_PREFIX", "value": "openwhisk"},
          {"name": "DOCKER_IMAGE_TAG", "value": "latest"},
          {"name": "DOCKER_REGISTRY", "value": ""},
          {"name": "INVOKER_OPTS", "value": " -Dkubernetes.master=https://$KUBERNETES_SERVICE_HOST -Dwhisk.spi.ContainerFactoryProvider=org.apache.openwhisk.core.containerpool.kubernetes.KubernetesContainerFactoryProvider -Dwhisk.kubernetes.timeouts.run=180s -Dwhisk.kubernetes.timeouts.logs=180s"}
        ]
      }
    ]'
}

kubectl rollout restart statefulset owdev-invoker -n openwhisk
kubectl rollout status statefulset owdev-invoker -n openwhisk --timeout=300s

echo ""
kubectl get pods -n openwhisk -o wide
echo ""
echo "OpenWhisk API: https://192.168.27.16:31001"
echo "Auth: 23bc46b1-71f6-4ed5-8c54-816aa4f8c502:123zO3xZCLrMN6v2BKK1dXYFpXlPkccOFqm12CZBkROBjVUW"