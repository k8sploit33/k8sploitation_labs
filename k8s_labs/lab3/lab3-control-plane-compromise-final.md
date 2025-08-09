# Lab 3 – Control-Plane Compromise via Kubeconfig in Pod

## Goal
Demonstrate how a pod with a `cluster-admin` kubeconfig can control the Kubernetes control plane.

---

## Step 0 – Create a dedicated k3d cluster

```bash
k3d cluster create lab3 --agents 2 --port 8083:80@loadbalancer
kubectl config use-context k3d-lab3
kubectl get nodes
```

---

## Step 1 – Create ServiceAccount and token secret via manifest

```bash
# Create the ServiceAccount and bind it to cluster-admin
kubectl create serviceaccount lab3-admin -n kube-system

kubectl create clusterrolebinding lab3-admin-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:lab3-admin
```

Create the following file as `lab3-admin-token.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: lab3-admin-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: lab3-admin
type: kubernetes.io/service-account-token
```

Apply it:

```bash
kubectl apply -f lab3-admin-token.yaml
```

Wait a few seconds, then verify:

```bash
kubectl -n kube-system get secret lab3-admin-token -o yaml
```

Ensure you see `data.token` and `data.ca.crt` fields populated.

---

## Step 2 – Extract credentials and create kubeconfig for in-cluster use

**Important:** Use the in-cluster API address so it works from inside pods.

```bash
TOKEN=$(kubectl -n kube-system get secret lab3-admin-token -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl -n kube-system get secret lab3-admin-token -o jsonpath='{.data.ca\.crt}')
SERVER=https://kubernetes.default.svc  # in-cluster API address
```

```bash
cat > attacker.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: k3d-lab3
  cluster:
    certificate-authority-data: ${CA_CERT}
    server: ${SERVER}
contexts:
- name: attacker-context
  context:
    cluster: k3d-lab3
    user: attacker
current-context: attacker-context
users:
- name: attacker
  user:
    token: ${TOKEN}
EOF
```

---

## Step 3 – Create ConfigMap for kubeconfig

```bash
kubectl create configmap attacker-kubeconfig --from-file=config=attacker.kubeconfig --dry-run=client -o yaml | kubectl apply -f -
```

---

## Step 4 – Deploy attacker pod with kubeconfig mounted

**attacker-kubeconfig-pod.yaml**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: attacker-kubeconfig
  namespace: default
spec:
  containers:
  - name: attacker
    image: bitnami/kubectl:latest
    imagePullPolicy: Always
    command: ["sleep","infinity"]
    env:
    - name: KUBECONFIG
      value: /kcfg/config
    volumeMounts:
    - name: kubeconfig
      mountPath: /kcfg
      readOnly: true
  volumes:
  - name: kubeconfig
    configMap:
      name: attacker-kubeconfig
```

```bash
kubectl apply -f attacker-kubeconfig-pod.yaml

kubectl get pods # wait for attack pod running. May take a few minutes
```

---

## Step 5 – Demo the compromise

```bash
# Verify kubectl sees the attacker context
kubectl exec attacker-kubeconfig -- kubectl config view

# Confirm full admin powers
kubectl exec attacker-kubeconfig -- kubectl auth can-i --list | head -n 20

# List secrets cluster-wide
kubectl exec attacker-kubeconfig -- kubectl get secrets --all-namespaces | head

# Sabotage example: scale nginx deployment in lab3-demo namespace to 0 replicas
kubectl create ns lab3-demo
kubectl -n lab3-demo create deploy nginx --image=nginx --replicas=2
kubectl -n lab3-demo rollout status deploy/nginx

kubectl -n lab3-demo patch deploy nginx \
  --type=json -p='[{"op":"replace","path":"/spec/replicas","value":0}]'
kubectl -n lab3-demo get deploy nginx -o custom-columns=NAME:.metadata.name,REPLICAS:.status.replicas,READY:.status.readyReplicas

```

---

## Step 6 – Cleanup

```bash
kubectl delete pod attacker-kubeconfig
kubectl delete clusterrolebinding lab3-admin-binding
kubectl delete serviceaccount lab3-admin -n kube-system
kubectl delete secret lab3-admin-token -n kube-system
kubectl delete configmap attacker-kubeconfig
kubectl delete -f lab3-admin-token.yaml
```

---

## Step 7 – Tear down the cluster

```bash
k3d cluster delete lab3
```

---

## Mitigations

- **Never bake kubeconfigs into images** — store credentials securely.
- **Set `automountServiceAccountToken: false`** for non-privileged pods.
- **Use least privilege RBAC** — avoid cluster-admin where unnecessary.
- **Rotate credentials and audit role bindings** regularly.