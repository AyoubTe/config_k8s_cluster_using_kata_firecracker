#!/bin/bash
set -e

export KUBECONFIG=/etc/kubernetes/admin.conf

# "====== Generating TLS cert for webhook ======"
mkdir -p /tmp/webhook-certs
cat > /tmp/webhook-certs/csr.conf <<CSREOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = kata-webhook.openwhisk.svc
DNS.2 = kata-webhook.openwhisk.svc.cluster.local
CSREOF

openssl genrsa -out /tmp/webhook-certs/ca.key 2048 2>/dev/null
openssl req -x509 -new -nodes -key /tmp/webhook-certs/ca.key \
    -subj "/CN=kata-webhook-ca" -days 3650 \
    -out /tmp/webhook-certs/ca.crt 2>/dev/null

openssl genrsa -out /tmp/webhook-certs/tls.key 2048 2>/dev/null
openssl req -new -key /tmp/webhook-certs/tls.key \
    -subj "/CN=kata-webhook.openwhisk.svc" \
    -out /tmp/webhook-certs/tls.csr 2>/dev/null
openssl x509 -req -in /tmp/webhook-certs/tls.csr \
    -CA /tmp/webhook-certs/ca.crt -CAkey /tmp/webhook-certs/ca.key \
    -CAcreateserial -out /tmp/webhook-certs/tls.crt \
    -days 3650 -extensions v3_req \
    -extfile /tmp/webhook-certs/csr.conf 2>/dev/null

CA_BUNDLE=$(base64 -w0 /tmp/webhook-certs/ca.crt)

# "====== Creating webhook TLS secret ======"
kubectl delete secret kata-webhook-tls -n openwhisk 2>/dev/null || true
kubectl create secret tls kata-webhook-tls \
    --cert=/tmp/webhook-certs/tls.crt \
    --key=/tmp/webhook-certs/tls.key \
    -n openwhisk

# "====== Deploying webhook server ======"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kata-webhook
  namespace: openwhisk
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kata-webhook
  template:
    metadata:
      labels:
        app: kata-webhook
    spec:
      containers:
      - name: webhook
        image: python:3.9-alpine
        command:
        - python3
        - -c
        - |
          import json, ssl, base64
          from http.server import HTTPServer, BaseHTTPRequestHandler

          class WebhookHandler(BaseHTTPRequestHandler):
              def log_message(self, format, *args):
                  pass
              def do_POST(self):
                  length = int(self.headers['Content-Length'])
                  body = json.loads(self.rfile.read(length))
                  uid = body["request"]["uid"]
                  obj = body["request"]["object"]
                  name = obj.get("metadata", {}).get("name", "") or \
                         obj.get("metadata", {}).get("generateName", "")
                  patch = []
                  if "wskowdev" in name:
                      patch.append({"op":"add","path":"/spec/runtimeClassName","value":"kata-fc"})
                  response = {
                      "apiVersion": "admission.k8s.io/v1",
                      "kind": "AdmissionReview",
                      "response": {
                          "uid": uid,
                          "allowed": True
                      }
                  }
                  if patch:
                      response["response"]["patchType"] = "JSONPatch"
                      response["response"]["patch"] = base64.b64encode(
                          json.dumps(patch).encode()).decode()
                  out = json.dumps(response).encode()
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(out)))
                  self.end_headers()
                  self.wfile.write(out)

          ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
          ctx.load_cert_chain("/certs/tls.crt", "/certs/tls.key")
          server = HTTPServer(("0.0.0.0", 8443), WebhookHandler)
          server.socket = ctx.wrap_socket(server.socket, server_side=True)
          print("Webhook listening on :8443")
          server.serve_forever()
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        secret:
          secretName: kata-webhook-tls
---
apiVersion: v1
kind: Service
metadata:
  name: kata-webhook
  namespace: openwhisk
spec:
  selector:
    app: kata-webhook
  ports:
  - port: 443
    targetPort: 8443
EOF

# "Waiting for webhook pod to be ready..."
kubectl rollout status deployment kata-webhook -n openwhisk --timeout=120s

# "====== Registering MutatingAdmissionWebhook ======"
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kata-fc-injector
webhooks:
- name: kata-fc-injector.openwhisk.svc
  admissionReviewVersions: ["v1"]
  sideEffects: None
  clientConfig:
    service:
      name: kata-webhook
      namespace: openwhisk
      path: /mutate
    caBundle: ${CA_BUNDLE}
  rules:
  - operations: ["CREATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: openwhisk
  failurePolicy: Ignore
EOF

# "====== Restarting invoker to trigger new prewarm pods ======"
kubectl rollout restart statefulset owdev-invoker -n openwhisk
kubectl rollout status statefulset owdev-invoker -n openwhisk --timeout=120s

# "Waiting 30s for prewarm pods..."
sleep 30

# "====== Verifying runtimeClassName on action pods ======"
kubectl get pods -n openwhisk -o custom-columns="NAME:.metadata.name,RUNTIME:.spec.runtimeClassName" | grep wskowdev