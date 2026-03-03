#!/bin/bash
# k3s server node initialization script
# Installs k3s in server mode and bootstraps ArgoCD after the cluster is ready.
#
# Optional VPN-gated firewall + ArgoCD ingress:
#   Set VPN_SUBNET before running (or export it from user_data) to enable:
#     - SSH and k3s API restricted to VPN peers (100.64.0.0/10 by default)
#     - ArgoCD UI exposed via Traefik with a VPN IP-allowlist
#   Compatible with NordVPN Meshnet and Tailscale (both use 100.64.0.0/10).
#   Example: VPN_SUBNET=100.64.0.0/10 bash init.sh

set -euo pipefail

ARGOCD_VERSION="v2.14.2"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"
REPO_K8S_DIR="${REPO_ROOT}/k8s"

# ── Auto-detect git repo URL and patch application.yaml placeholders ──────────
REPO_URL=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "")
# Convert SSH remote (git@github.com:org/repo.git) to HTTPS so ArgoCD can
# clone without SSH keys. HTTPS works for both public and token-authed repos.
if echo "${REPO_URL}" | grep -q "^git@"; then
  REPO_URL="https://$(echo "${REPO_URL}" | sed 's|git@||;s|:|/|')"
fi
if [ -n "${REPO_URL}" ]; then
  echo "Detected repo URL: ${REPO_URL}"
  # Patch all application.yaml files AND app-of-apps.yaml
  find "${REPO_K8S_DIR}" \( -name "application.yaml" -o -name "app-of-apps.yaml" \) \
    -exec sed -i "s|https://github.com/YOUR_ORG/YOUR_REPO.git|${REPO_URL}|g" {} \;
  echo "Patched repoURL in all application.yaml + app-of-apps.yaml files."
else
  echo "WARNING: Could not detect git remote URL. Placeholders in application.yaml not patched."
  echo "  Set repoURL manually or push to a git remote before running."
fi

# ── Auto-detect public node IP ─────────────────────────────────────────────────
NODE_IP="${NODE_IP:-$(
  curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null ||
  curl -sf --max-time 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null ||
  curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo ""
)}"
if [ -n "${NODE_IP}" ]; then
  echo "Detected node IP: ${NODE_IP}"
else
  echo "WARNING: Could not auto-detect node IP. ArgoCD ingress will use example.com placeholder."
  echo "  Set NODE_IP env var before running, or edit ingress.yaml manually after bootstrap."
fi

echo "Starting k3s server setup..."

# ── 1. Install k3s server ────────────────────────────────────────────────────
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644

# Wait for the node to become Ready
echo "Waiting for k3s to be ready..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done
echo "k3s node is Ready."

# ── 2. Export node token (worker nodes need this to join) ─────────────────────
NODE_TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
echo "Node token stored at: ${NODE_TOKEN_FILE}"
echo "Worker nodes need: K3S_URL=https://<this-ip>:6443  K3S_TOKEN=$(cat ${NODE_TOKEN_FILE})"

# ── 3. Install ArgoCD ─────────────────────────────────────────────────────────
echo "Creating argocd namespace..."
kubectl apply -f "${REPO_K8S_DIR}/system/argocd/install.yaml"

echo "Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n argocd -f "${ARGOCD_INSTALL_URL}"

echo "Waiting for ArgoCD server to be ready (up to 5 min)..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s

# ── 4. Apply app-of-apps ──────────────────────────────────────────────────────
echo "Applying ArgoCD app-of-apps..."
kubectl apply -f "${REPO_K8S_DIR}/system/argocd/app-of-apps.yaml"

# ── 5. Install cert-manager ──────────────────────────────────────────────────
echo "Installing cert-manager..."
kubectl apply -f "${REPO_K8S_DIR}/system/cert-manager/application.yaml"

echo "Waiting for cert-manager namespace (ArgoCD syncs it — up to 3 min)..."
until kubectl get namespace cert-manager &>/dev/null; do sleep 5; done
echo "Waiting for cert-manager deployments to be available (controller + webhook)..."
kubectl wait --for=condition=available deployment/cert-manager \
  -n cert-manager --timeout=180s
# The webhook must be ready before ClusterIssuer CRs can be accepted
kubectl wait --for=condition=available deployment/cert-manager-webhook \
  -n cert-manager --timeout=120s

LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-you@example.com}"
sed -i "s|you@example.com|${LETSENCRYPT_EMAIL}|g" \
  "${REPO_K8S_DIR}/system/cert-manager/cluster-issuers.yaml"
echo "Applying ClusterIssuers..."
kubectl apply -f "${REPO_K8S_DIR}/system/cert-manager/cluster-issuers.yaml"

# ── 7. Bootstrap ESO + Infisical ─────────────────────────────────────────────
echo "Applying External Secrets Operator..."
kubectl apply -f "${REPO_K8S_DIR}/system/external-secrets/application.yaml"

echo "Applying Infisical system..."
kubectl apply -f "${REPO_K8S_DIR}/system/infisical/application.yaml"

echo "Waiting for external-secrets namespace (ArgoCD syncs it — up to 3 min)..."
for i in $(seq 1 36); do
  kubectl get namespace external-secrets &>/dev/null && break; sleep 5
done
kubectl get namespace external-secrets &>/dev/null || \
  { echo "ERROR: external-secrets namespace not created after 3 min"; exit 1; }
echo "external-secrets namespace ready."

echo "Waiting for infisical namespace (ArgoCD syncs it — up to 3 min)..."
for i in $(seq 1 36); do
  kubectl get namespace infisical &>/dev/null && break; sleep 5
done
kubectl get namespace infisical &>/dev/null || \
  { echo "ERROR: infisical namespace not created after 3 min"; exit 1; }
echo "infisical namespace ready."

ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(openssl rand -hex 16)}"
AUTH_SECRET="${AUTH_SECRET:-$(openssl rand -hex 16)}"
kubectl create secret generic infisical-secrets -n infisical \
  --from-literal=ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=AUTH_SECRET="${AUTH_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "infisical-secrets applied."

INFISICAL_CLIENT_ID="${INFISICAL_CLIENT_ID:-placeholder}"
INFISICAL_CLIENT_SECRET="${INFISICAL_CLIENT_SECRET:-placeholder}"
if [ "${INFISICAL_CLIENT_ID}" = "placeholder" ]; then
  echo "WARNING: Using placeholder Infisical credentials. Secret sync will not work."
  echo "  Set INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET to enable sync."
fi
kubectl create secret generic infisical-credentials -n external-secrets \
  --from-literal=clientId="${INFISICAL_CLIENT_ID}" \
  --from-literal=clientSecret="${INFISICAL_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "infisical-credentials applied."

# ── 8. VPN-gated firewall + ArgoCD ingress (optional) ─────────────────────────
if [ -n "${VPN_SUBNET:-}" ]; then
  echo ""
  echo "VPN_SUBNET is set (${VPN_SUBNET}). Configuring VPN-gated access..."

  # Firewall: restrict SSH + k3s API to VPN peers
  VPN_SUBNET="${VPN_SUBNET}" bash "${SETUP_DIR}/vpn-firewall.sh"

  # ArgoCD: run insecure so Traefik can apply the IP-allowlist middleware
  kubectl apply -f "${REPO_K8S_DIR}/system/argocd/argocd-params.yaml"
  kubectl rollout restart deployment/argocd-server -n argocd
  kubectl rollout status  deployment/argocd-server -n argocd --timeout=120s

  # Expose ArgoCD UI via Traefik with VPN IP-allowlist
  kubectl apply -f "${REPO_K8S_DIR}/system/argocd/vpn-middleware.yaml"
  if [ -n "${NODE_IP}" ]; then
    ARGOCD_HOST="argocd.${NODE_IP}.nip.io"
    sed "s|argocd\.example\.com|${ARGOCD_HOST}|g" \
      "${REPO_K8S_DIR}/system/argocd/ingress.yaml" | kubectl apply -f -
  else
    kubectl apply -f "${REPO_K8S_DIR}/system/argocd/ingress.yaml"
    ARGOCD_HOST="argocd.example.com"
  fi

  echo ""
  echo "VPN-gated access configured."
  echo "  ArgoCD UI: http://${ARGOCD_HOST}"
  echo "  Access requires a VPN peer address in ${VPN_SUBNET}."
else
  echo ""
  echo "VPN_SUBNET not set — skipping firewall hardening and ArgoCD ingress."
  echo "  Re-run with VPN_SUBNET=100.64.0.0/10 to enable VPN-gated access."
fi

echo ""
echo "k3s + ArgoCD setup complete."
echo ""
echo "Useful commands:"
echo "  kubectl get nodes"
echo "  kubectl get pods -n argocd"
echo "  kubectl get applications -n argocd"
echo ""
echo "ArgoCD admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
