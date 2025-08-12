#!/usr/bin/env bash
set -euo pipefail

NS1=flag-1
NS2=flag-2
PIECE1='K7$g9!4z'
PIECE2='N@pE2d#8'

echo "[*] Shura: creating namespaces"
k3s kubectl create ns "$NS1" --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl create ns "$NS2" --dry-run=client -o yaml | k3s kubectl apply -f -

echo "[*] Shura: placing host flag for Flag 1 at /flag1"
echo -n "$PIECE1" | sudo tee /flag1 >/dev/null
sudo chmod 644 /flag1

echo "[*] Shura: deploying Flag 1 pod (escape-pod)"
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod
  namespace: flag-1
  labels: {app: escape}
spec:
  hostPID: true
  containers:
  - name: c
    image: alpine:3.20
    securityContext:
      privileged: true
    command: ["/bin/sh","-c"]
    args:
      - |
        echo "[escape-pod] /host is mounted from the node. Try reading /host/flag1";
        sleep 3600
    volumeMounts:
    - name: hostroot
      mountPath: /host
  volumes:
  - name: hostroot
    hostPath: { path: /, type: Directory }
  restartPolicy: Always
YAML

echo "[*] Shura: creating Flag 2 secret and RBAC (default SA can read only this secret)"
k3s kubectl -n "$NS2" delete secret flag2 --ignore-not-found
k3s kubectl -n "$NS2" create secret generic flag2 --from-literal=flag="$PIECE2"

cat <<'YAML' | k3s kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: leaky-read, namespace: flag-2}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["flag2"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: leaky-read-bind, namespace: flag-2}
subjects:
- kind: ServiceAccount
  name: default
  namespace: flag-2
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: leaky-read
YAML

echo "[*] Shura: deploying Flag 2 helper pod (prints token + CA in logs)"
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: sa-leak, namespace: flag-2}
spec:
  containers:
  - name: c
    image: curlimages/curl:8.10.1
    command: ["/bin/sh","-c"]
    args:
      - |
        echo "-----SA TOKEN (first 50)-----";
        head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token; echo;
        echo "-----SA CA (base64, first 60)-----";
        base64 /var/run/secrets/kubernetes.io/serviceaccount/ca.crt | head -c 60; echo;
        echo "Hint: curl with Bearer token + --cacert to read /api/v1/namespaces/flag-2/secrets/flag2";
        sleep 3600
  restartPolicy: Never
YAML

echo "Flags 1 and 2 ready."
