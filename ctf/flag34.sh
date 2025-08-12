#!/usr/bin/env bash
set -euo pipefail

NS3=flag-3
NS4=flag-4
PIECE3='Qx5&u1T%'
PIECE4='mZ!3b9^L'
VM_IP="${VM_IP:-192.168.60.181}"   # export VM_IP=... before running to override
CLUSTER="shaka"

echo "[*] Shaka: creating namespaces"
k3s kubectl create ns "$NS3" --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl create ns "$NS4" --dry-run=client -o yaml | k3s kubectl apply -f -

echo "[*] Shaka: Flag 3 secret + SA + RBAC"
k3s kubectl -n "$NS3" delete secret deploy-flag --ignore-not-found
k3s kubectl -n "$NS3" create secret generic deploy-flag --from-literal=flag="$PIECE3"

# SA that the baked kubeconfig will use
k3s kubectl -n "$NS3" create sa baked-sa --dry-run=client -o yaml | k3s kubectl apply -f -

# Allow baked-sa to read ONLY that secret
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: deploy-flag-read, namespace: flag-3}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["deploy-flag"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: deploy-flag-read-bind, namespace: flag-3}
subjects:
- kind: ServiceAccount
  name: baked-sa
  namespace: flag-3
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deploy-flag-read
YAML

# Mint a token and bake a kubeconfig into a ConfigMap
TOKEN="$(k3s kubectl -n "$NS3" create token baked-sa --duration=12h)"
cat > /tmp/baked-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: https://${VM_IP}:6443
    insecure-skip-tls-verify: true
contexts:
- name: baked-sa@${CLUSTER}
  context:
    cluster: ${CLUSTER}
    namespace: ${NS3}
    user: baked-sa
current-context: baked-sa@${CLUSTER}
users:
- name: baked-sa
  user:
    token: ${TOKEN}
EOF

echo "[*] Shaka: storing baked kubeconfig in ConfigMap + mounting into a pod"
k3s kubectl -n "$NS3" create configmap baked-kubeconfig --from-file=kubeconfig=/tmp/baked-kubeconfig.yaml --dry-run=client -o yaml | k3s kubectl apply -f -

cat <<'YAML' | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kubeconf-pod
  namespace: flag-3
spec:
  containers:
  - name: c
    image: bitnami/kubectl:latest
    command: ["sh","-lc","echo 'Find the kubeconfig at /opt/kube/kubeconfig'; sleep 3600"]
    volumeMounts:
    - name: kcfg
      mountPath: /opt/kube
  volumes:
  - name: kcfg
    configMap:
      name: baked-kubeconfig
      items:
      - key: kubeconfig
        path: kubeconfig
  restartPolicy: Never
YAML

echo "[*] Shaka: Flag 4 echo service (NodePort -> external)"
cat <<YAML | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: websrv
  namespace: ${NS4}
  labels: {app: websrv}
spec:
  containers:
  - name: web
    image: hashicorp/http-echo
    args: ["-text=${PIECE4}","-listen=:5678"]
---
apiVersion: v1
kind: Service
metadata:
  name: websrv
  namespace: ${NS4}
spec:
  selector: {app: websrv}
  type: NodePort
  ports:
  - port: 5678
    targetPort: 5678
    nodePort: 30080
YAML

echo "Flags 3 and 4 ready. (Flag4 via: curl http://${VM_IP}:30080)"
