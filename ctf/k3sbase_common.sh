#!/usr/bin/env bash
set -euo pipefail

# ===== Config (optional overrides via env) =====
VM_IP="${VM_IP:-}"                         # e.g. 192.168.60.171; auto-detected if empty
CLUSTER="${CLUSTER:-$(hostname -s)}"       
CTFUSER="${CTFUSER:-ctfuser}"
CTFUSER_PW="${CTFUSER_PW:-}"               # optional: set to give ctfuser a password
# ==============================================

echo "[*] Detecting IP..."
if [ -z "$VM_IP" ]; then
  # pick first non-loopback IPv4
  VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [ -z "$VM_IP" ]; then
  VM_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')"
fi
[ -n "$VM_IP" ] || { echo "[-] Could not auto-detect VM_IP. Export VM_IP and re-run."; exit 1; }

echo "[*] Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates iptables openssh-server

echo "[*] Creating '${CTFUSER}' (no sudo)..."
if ! id -u "$CTFUSER" >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" "$CTFUSER"
  if [ -n "$CTFUSER_PW" ]; then
    echo "${CTFUSER}:${CTFUSER_PW}" | sudo chpasswd
  fi
fi
# ensure not in sudo
sudo gpasswd -d "$CTFUSER" sudo 2>/dev/null || true

echo "[*] Writing k3s config at /etc/rancher/k3s/config.yaml ..."
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
# Workshop base config
bind-address: "0.0.0.0"          # API listens on all interfaces
node-ip: "${VM_IP}"
advertise-address: "${VM_IP}"
tls-san:
  - "${VM_IP}"
  - "${CLUSTER}"
disable-network-policy: true      # avoid NP controller issues in lab
# write-kubeconfig-mode: "0640"   # default is fine; uncomment if you prefer
EOF

echo "[*] Installing k3s server..."
# Uses latest stable k3s. If you need a pinned version: INSTALL_K3S_VERSION="v1.33.3+k3s1"
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="server" sh -

echo "[*] Opening API port 6443..."
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -qi active; then
  sudo ufw allow 6443/tcp || true
else
  sudo iptables -C INPUT -p tcp --dport 6443 -j ACCEPT 2>/dev/null || \
  sudo iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
fi

echo "[*] Providing a kubectl wrapper (uses k3s kubectl)..."
sudo tee /usr/local/bin/kubectl >/dev/null <<'WRAP'
#!/bin/sh
exec k3s kubectl "$@"
WRAP
sudo chmod +x /usr/local/bin/kubectl

echo "[*] Securing admin kubeconfig..."
sudo chown root:root /etc/rancher/k3s/k3s.yaml
sudo chmod 600       /etc/rancher/k3s/k3s.yaml

echo "[*] Creating workshop directories..."
sudo -u "$CTFUSER" mkdir -p "/home/${CTFUSER}/"{challenges,keys}
sudo chown -R "$CTFUSER:$CTFUSER" "/home/${CTFUSER}/challenges" "/home/${CTFUSER}/keys"
sudo chmod 700 "/home/${CTFUSER}/keys"

echo
echo "  Base ready on $(hostname -s) (${CLUSTER})."
echo "   Server: https://${VM_IP}:6443"
echo "   Admin kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo "   Student key drop: /home/${CTFUSER}/keys"
echo
echo "Next: run your flag scripts for this host (Flag12, flag34, or final flag."
