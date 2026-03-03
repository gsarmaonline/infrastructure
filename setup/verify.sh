#!/bin/bash
# Verify cluster health after bootstrap.
# Checks every layer in order and prints ✓/✗ for each.
# At the end prints an access summary with URLs and the ArgoCD admin password.
#
# Usage:
#   bash verify.sh              # auto-detects NODE_IP from metadata
#   NODE_IP=1.2.3.4 bash verify.sh   # explicit override

set -uo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"
REPO_K8S_DIR="${REPO_ROOT}/k8s"

PASS="✓"
FAIL="✗"
WARN="⚠"

ok()   { echo "  ${PASS} $*"; }
fail() { echo "  ${FAIL} $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  ${WARN} $*"; }

FAILURES=0

# ── Auto-detect public node IP ─────────────────────────────────────────────────
NODE_IP="${NODE_IP:-$(
  curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null ||
  curl -sf --max-time 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null ||
  curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo ""
)}"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Cluster Health Verification"
echo "═══════════════════════════════════════════════════"
if [ -n "${NODE_IP}" ]; then
  echo "  NODE_IP: ${NODE_IP}"
else
  warn "NODE_IP not detected — nip.io patch will be skipped"
fi
echo ""

# ── 1. k3s node Ready ─────────────────────────────────────────────────────────
echo "[ 1 ] k3s node"
if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
  NODE_NAME=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' | head -1)
  ok "Node ${NODE_NAME} is Ready"
else
  fail "No Ready node found (is k3s running?)"
fi

# ── 2. ArgoCD server + Applications ───────────────────────────────────────────
echo ""
echo "[ 2 ] ArgoCD"
if kubectl get deployment argocd-server -n argocd --no-headers 2>/dev/null | grep -q " 1/1"; then
  ok "argocd-server deployment is Available"
else
  fail "argocd-server deployment not ready"
fi

# Check each Application
NOT_SYNCED=()
while IFS= read -r line; do
  APP_NAME=$(echo "${line}" | awk '{print $1}')
  SYNC=$(echo "${line}"    | awk '{print $2}')
  HEALTH=$(echo "${line}"  | awk '{print $3}')
  if [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
    ok "Application ${APP_NAME}: Synced/Healthy"
  else
    fail "Application ${APP_NAME}: ${SYNC}/${HEALTH}"
    NOT_SYNCED+=("${APP_NAME}")
  fi
done < <(kubectl get applications -n argocd --no-headers 2>/dev/null || true)

if [ ${#NOT_SYNCED[@]} -gt 0 ]; then
  warn "Unhealthy apps: ${NOT_SYNCED[*]}"
  warn "  Run: kubectl describe application <name> -n argocd"
fi

# ── 3. cert-manager pods + ClusterIssuers ─────────────────────────────────────
echo ""
echo "[ 3 ] cert-manager"
CERT_MANAGER_READY=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null \
  | awk '{print $2}' | grep -v "1/1\|2/2\|3/3" | wc -l | tr -d ' ')
CERT_MANAGER_TOTAL=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "${CERT_MANAGER_TOTAL}" -gt 0 ] && [ "${CERT_MANAGER_READY}" -eq 0 ]; then
  ok "cert-manager pods running (${CERT_MANAGER_TOTAL} pods)"
else
  fail "cert-manager pods not all ready (${CERT_MANAGER_READY} not ready of ${CERT_MANAGER_TOTAL})"
fi

for ISSUER in letsencrypt-staging letsencrypt-prod; do
  STATUS=$(kubectl get clusterissuer "${ISSUER}" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
  if [ "${STATUS}" = "Ready" ]; then
    ok "ClusterIssuer ${ISSUER} is Ready"
  else
    fail "ClusterIssuer ${ISSUER} not Ready (status: ${STATUS:-not found})"
  fi
done

# ── 4. Certificates across all namespaces ─────────────────────────────────────
echo ""
echo "[ 4 ] Certificates"
CERT_COUNT=0
CERT_NOT_READY=0
while IFS= read -r line; do
  CERT_COUNT=$((CERT_COUNT + 1))
  CERT_NAME=$(echo "${line}" | awk '{print $1}')
  CERT_NS=$(echo "${line}"   | awk '{print $2}')
  CERT_RDY=$(echo "${line}"  | awk '{print $3}')
  if [ "${CERT_RDY}" = "True" ]; then
    ok "Certificate ${CERT_NS}/${CERT_NAME}: Ready"
  else
    fail "Certificate ${CERT_NS}/${CERT_NAME}: not Ready"
    CERT_NOT_READY=$((CERT_NOT_READY + 1))
  fi
done < <(kubectl get certificates -A --no-headers 2>/dev/null \
  | awk '{print $2, $1, $3}' || true)

if [ "${CERT_COUNT}" -eq 0 ]; then
  warn "No certificates found yet (ArgoCD may still be syncing)"
fi

# ── 5. nip.io patch for example-app ingress ───────────────────────────────────
echo ""
echo "[ 5 ] example-app nip.io ingress patch"

EXAMPLE_APP_URL=""
if [ -n "${NODE_IP}" ]; then
  EXAMPLE_DOMAIN="example-app.${NODE_IP}.nip.io"
  EXAMPLE_TLS_SECRET="example-app-${NODE_IP//./-}-tls"
  EXAMPLE_APP_URL="https://${EXAMPLE_DOMAIN}"

  # Patch only if the ingress exists
  if kubectl get ingress example-app -n example-app &>/dev/null; then
    kubectl patch ingress example-app -n example-app --type=json -p "[
      {\"op\": \"replace\", \"path\": \"/spec/rules/0/host\",         \"value\": \"${EXAMPLE_DOMAIN}\"},
      {\"op\": \"replace\", \"path\": \"/spec/tls/0/hosts/0\",        \"value\": \"${EXAMPLE_DOMAIN}\"},
      {\"op\": \"replace\", \"path\": \"/spec/tls/0/secretName\",     \"value\": \"${EXAMPLE_TLS_SECRET}\"}
    ]" 2>/dev/null && ok "Patched example-app ingress → ${EXAMPLE_DOMAIN}" \
                     || fail "Could not patch example-app ingress"
  else
    warn "example-app ingress not found yet (ArgoCD may still be syncing)"
  fi
else
  warn "NODE_IP not set — skipping example-app ingress nip.io patch"
  warn "  Set NODE_IP=<public-ip> and re-run to patch"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Access Summary"
echo "═══════════════════════════════════════════════════"

# ArgoCD URL
ARGOCD_HOST=""
if [ -n "${NODE_IP}" ]; then
  ARGOCD_HOST="argocd.${NODE_IP}.nip.io"
else
  ARGOCD_HOST=$(kubectl get ingress argocd -n argocd \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
fi

if [ -n "${ARGOCD_HOST}" ]; then
  echo "  ArgoCD UI:    http://${ARGOCD_HOST}"
else
  echo "  ArgoCD UI:    (ingress not configured — port-forward with:"
  echo "                   kubectl port-forward svc/argocd-server -n argocd 8080:443)"
fi

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(not found)")
echo "  ArgoCD login: admin / ${ARGOCD_PASSWORD}"

if [ -n "${EXAMPLE_APP_URL}" ]; then
  echo ""
  echo "  example-app:  ${EXAMPLE_APP_URL}"
  echo "  (cert-manager will issue a Let's Encrypt staging cert automatically)"
fi

echo ""
if [ "${FAILURES}" -eq 0 ]; then
  echo "  ${PASS} All checks passed."
else
  echo "  ${FAIL} ${FAILURES} check(s) failed — review the output above."
  exit 1
fi
echo ""
