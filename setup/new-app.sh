#!/bin/bash
# Scaffold a new app directory from the example-app template.
#
# Usage:
#   APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest bash new-app.sh
#   APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest PORT=8080 bash new-app.sh
#   APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest DOMAIN=api.example.com bash new-app.sh
#
# Required:
#   APP_NAME  — name for the app (used for namespace, labels, resource names)
#   IMAGE     — container image (e.g. ghcr.io/org/my-api:latest)
#
# Optional:
#   PORT      — container + service port (default: 80)
#   DOMAIN    — ingress hostname (default: <APP_NAME>.<NODE_IP>.nip.io)
#   NODE_IP   — public IP of node for nip.io domain (auto-detected if not set)

set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"
REPO_K8S_DIR="${REPO_ROOT}/k8s"
TEMPLATE_DIR="${REPO_K8S_DIR}/apps/example-app"

# ── Validate required args ─────────────────────────────────────────────────────
if [ -z "${APP_NAME:-}" ]; then
  echo "ERROR: APP_NAME is required." >&2
  echo "  Usage: APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest bash new-app.sh" >&2
  exit 1
fi

if [ -z "${IMAGE:-}" ]; then
  echo "ERROR: IMAGE is required." >&2
  echo "  Usage: APP_NAME=${APP_NAME} IMAGE=ghcr.io/org/my-api:latest bash new-app.sh" >&2
  exit 1
fi

PORT="${PORT:-80}"

# ── Auto-detect NODE_IP for default domain ────────────────────────────────────
if [ -z "${NODE_IP:-}" ]; then
  NODE_IP=$(
    curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null ||
    curl -sf --max-time 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null ||
    curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo ""
  )
fi

if [ -n "${NODE_IP}" ]; then
  DOMAIN="${DOMAIN:-${APP_NAME}.${NODE_IP}.nip.io}"
else
  DOMAIN="${DOMAIN:-${APP_NAME}.example.com}"
fi

# ── Auto-detect git repo URL ───────────────────────────────────────────────────
REPO_URL=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "https://github.com/YOUR_ORG/YOUR_REPO.git")

# ── Target directory ───────────────────────────────────────────────────────────
TARGET_DIR="${REPO_K8S_DIR}/apps/${APP_NAME}"

if [ -d "${TARGET_DIR}" ]; then
  echo "ERROR: ${TARGET_DIR} already exists. Remove it first or choose a different APP_NAME." >&2
  exit 1
fi

echo "Scaffolding app: ${APP_NAME}"
echo "  Image:  ${IMAGE}"
echo "  Port:   ${PORT}"
echo "  Domain: ${DOMAIN}"
echo "  Repo:   ${REPO_URL}"
echo ""

# ── Copy template ──────────────────────────────────────────────────────────────
cp -r "${TEMPLATE_DIR}" "${TARGET_DIR}"

# ── Apply substitutions across all copied files ────────────────────────────────
# Use a portable sed invocation that works on both GNU and BSD (macOS) sed.
# BSD sed requires -i '' while GNU sed accepts -i '' or -i.
SED_INPLACE=(-i '')
if sed --version 2>/dev/null | grep -q 'GNU'; then
  SED_INPLACE=(-i)
fi

run_sed() {
  find "${TARGET_DIR}" -type f \
    -exec sed "${SED_INPLACE[@]}" "$@" {} \;
}

# App name (namespace, resource names, labels, selector)
run_sed "s|example-app|${APP_NAME}|g"

# Container image
run_sed "s|nginx:stable-alpine|${IMAGE}|g"

# TLS secret name
run_sed "s|${APP_NAME}-tls|${APP_NAME}-tls|g"    # already correct after app-name substitution
run_sed "s|example-app-tls|${APP_NAME}-tls|g"     # catch any remaining literal (none expected)

# Secret names
run_sed "s|${APP_NAME}-secrets|${APP_NAME}-secrets|g"   # already correct

# Domain / ingress host
run_sed "s|example-app\.example\.com|${DOMAIN}|g"
run_sed "s|example-app\.${NODE_IP:-}\.nip\.io|${DOMAIN}|g" 2>/dev/null || true

# Port substitution (only if different from default 80)
if [ "${PORT}" != "80" ]; then
  run_sed "s|containerPort: 80|containerPort: ${PORT}|g"
  run_sed "s|targetPort: 80|targetPort: ${PORT}|g"
  run_sed "s|port: 80|port: ${PORT}|g"
  run_sed "s|number: 80|number: ${PORT}|g"
fi

# Repo URL in application.yaml
run_sed "s|https://github.com/YOUR_ORG/YOUR_REPO.git|${REPO_URL}|g"

# ── Print next steps ───────────────────────────────────────────────────────────
echo "Created: ${TARGET_DIR}"
echo ""
echo "Files generated:"
find "${TARGET_DIR}" -type f | sort | while read -r f; do
  echo "  ${f#"${REPO_ROOT}/"}"
done
echo ""
echo "Review the files, then deploy:"
echo ""
echo "  git add k8s/apps/${APP_NAME}/"
echo "  git commit -m \"Add ${APP_NAME} app\""
echo "  git push"
echo ""
echo "ArgoCD will sync within ~3 minutes."
echo ""
echo "After sync, verify:"
echo "  kubectl get application ${APP_NAME} -n argocd"
echo "  kubectl get certificate -n ${APP_NAME}"
echo "  kubectl get pods -n ${APP_NAME}"
if [ "${DOMAIN}" != "${APP_NAME}.example.com" ]; then
  echo ""
  echo "  App URL: https://${DOMAIN}"
fi
