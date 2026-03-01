#!/bin/bash
# k3s server node initialization script
# Installs k3s in server mode and bootstraps ArgoCD after the cluster is ready.

set -euo pipefail

ARGOCD_VERSION="v2.14.2"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
REPO_K8S_DIR="/root/k8s"

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
