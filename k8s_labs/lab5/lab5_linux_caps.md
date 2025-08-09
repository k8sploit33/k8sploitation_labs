# Lab 5: Abusing Linux Capabilities

## Overview
In this lab, you'll explore how granting excessive Linux capabilities to pods (such as `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, and `CAP_SYS_PTRACE`) can lead to powerful host-level attacks.  
You'll perform:
1. Direct capability abuse inside a pod.
2. Capability persistence and transfer using a tarball.

---

## Cluster Setup

Create a dedicated k3d cluster for this lab:

```bash
k3d cluster create lab5   --agents 2   --api-port 6555   -p "8085:80@loadbalancer"   --k3s-arg "--disable=traefik@server:*"
```

---

## Deploy Attacker Pod with Dangerous Capabilities

We'll deploy an attacker pod with elevated capabilities.

```yaml
# lab5-attacker.yaml
apiVersion: v1
kind: Pod
metadata:
  name: attacker-pod
  namespace: default
spec:
  containers:
  - name: attacker
    image: alpine:3.19
    command: ["sleep", "infinity"]
    securityContext:
      capabilities:
        add:
          - SYS_ADMIN
          - NET_ADMIN
          - SYS_PTRACE
    stdin: true
    tty: true
```

Apply it:

```bash
kubectl apply -f lab5-attacker.yaml
kubectl wait --for=condition=Ready pod/attacker-pod
```

---

## Part 1: Direct Capability Abuse

### Step 1: Check Capabilities in the Pod
```bash
kubectl exec attacker-pod -- apk add libcap
kubectl exec attacker-pod -- capsh --print
```

---

### Step 2: Use `CAP_SYS_ADMIN` to Mount tmpfs and Access `/etc/passwd`
```bash
kubectl exec -it attacker-pod -- sh
mkdir /mnt/tmpfs
mount -t tmpfs none /mnt/tmpfs
cp /etc/passwd /mnt/tmpfs/
ls -l /mnt/tmpfs/passwd
exit
```

---

### Step 3: Use `CAP_NET_ADMIN` to Create a Rogue Bridge
```bash
kubectl exec -it attacker-pod -- sh
ip link add br0 type bridge
ip link set br0 up
ip addr add 10.0.0.1/24 dev br0
ping -c 1 10.0.0.1
exit
```

---

## Part 2: Capability Transport via Tarball

This simulates moving a privileged binary into a restricted pod while retaining its capabilities.

---

### Step 1: Build a Binary with `CAP_SYS_ADMIN` (Outside the Cluster)

On your local machine or a privileged container:

```bash
sudo apt update
sudo apt install -y libcap2-bin tar

cd ~/k8s_labs/lab5
echo -e '#!/bin/sh\necho "[*] Doing CAP_SYS_ADMIN things..."' > esc-tool
chmod +x esc-tool
sudo setcap cap_sys_admin+ep ./esc-tool

tar --xattrs --xattrs-include='security.capability' -czf esc-tool.tar.gz esc-tool
kubectl cp esc-tool.tar.gz attacker-pod:/tmp/

kubectl exec attacker-pod -- sh -lc '
  tar --xattrs --xattrs-include=security.capability -xzf /tmp/esc-tool.tar.gz -C /tmp/ &&
  getcap /tmp/esc-tool &&
  /tmp/esc-tool
'

```

---

### Step 2: Copy and Extract in the Pod

```bash
kubectl cp esc-tool.tar.gz attacker-pod:/tmp/
kubectl exec attacker-pod -- tar --xattrs --xattrs-include='security.capability' -xzf /tmp/esc-tool.tar.gz -C /tmp/
kubectl exec attacker-pod -- getcap /tmp/esc-tool
```

Expected output:
```
/tmp/esc-tool = cap_sys_admin=ep
```

---

### Step 3: Execute the Privileged Tool
```bash
kubectl exec attacker-pod -- /tmp/esc-tool --do-escalation
```

---

## Cleanup

```bash
k3d cluster delete lab5
```

---

## Mitigations
- Use **distroless** or **scratch** base images (no interpreters).
- Enforce **seccomp** / **AppArmor** to block unwanted syscalls.
- Monitor runtime with **Falco** or **Tracee**.
- Drop all capabilities by default.
- Enforce restrictions with **PodSecurity Admission**.
