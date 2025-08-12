#!/usr/bin/env bash
set -euo pipefail

NSV=ctf-vault
FINAL_B64='SFBFIE9TU08gUk9DS1Mh'   # "HPE OSSO ROCKS!" base64

echo "[*] Aiolia: creating namespace ${NSV}"
k3s kubectl create ns "$NSV" --dry-run=client -o yaml | k3s kubectl apply -f -

echo "[*] Aiolia: creating final flag secret"
k3s kubectl -n "$NSV" delete secret final-flag --ignore-not-found
k3s kubectl -n "$NSV" create secret generic final-flag --from-literal=flag="${FINAL_B64}"

echo "[*] Aiolia: limiting default SA to read only final-flag"
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: final-flag-read, namespace: ctf-vault}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["final-flag"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: final-flag-read-bind, namespace: ctf-vault}
subjects:
- kind: ServiceAccount
  name: default
  namespace: ctf-vault
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: final-flag-read
YAML

echo "[*] Aiolia: deploying helper pod"
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: aiolia-pod
  namespace: ctf-vault
spec:
  containers:
  - name: reader
    image: bitnami/kubectl:latest
    command: ["sh","-lc","echo 'Try using the in-pod token to read the secret'; sleep 3600"]
  restartPolicy: Never
YAML

echo "Final flag ready."
