#!/bin/bash
# Bootstrap a local k3s cluster inside a Multipass VM.
# Mirrors the production cloud setup as closely as possible.
#
# Differences from production:
#   - TLS: self-signed ClusterIssuer instead of Let's Encrypt
#   - Infisical credentials: stub values (ESO won't sync real secrets without
#     a real Machine Identity — see README for how to wire that up)
#   - VPN firewall: not applied (no VPN_SUBNET set)
#
# Prerequisites:
#   macOS:  brew install multipass
#   Linux:  snap install multipass
#
# Usage:
#   bash setup/local-setup.sh
#   VM_NAME=my-test VM_MEMORY=8G bash setup/local-setup.sh
#
# Re-running is safe — if the VM already exists it is reused.

set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"
REPO_BASENAME="$(basename "${REPO_ROOT}")"

VM_NAME="${VM_NAME:-infra-local}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY="${VM_MEMORY:-4G}"
VM_DISK="${VM_DISK:-20G}"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  → $*"; }
ok()      { echo "  ✓ $*"; }
warn()    { echo "  ⚠  $*"; }
fail()    { echo "  ✗ $*" >&2; exit 1; }

# Run a command as root inside the VM
vm_exec() { multipass exec "${VM_NAME}" -- sudo bash -c "$1"; }

# Run kubectl as root inside the VM
vm_kubectl() { multipass exec "${VM_NAME}" -- sudo kubectl "$@"; }

# ── 0. Check prerequisites ────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  Local Infrastructure Setup"
echo "  VM: ${VM_NAME}"
echo "══════════════════════════════════════════"
echo ""

if ! command -v multipass &>/dev/null; then
  fail "multipass not found. Install with:  brew install multipass  (macOS)  or  snap install multipass  (Linux)"
fi
ok "multipass $(multipass version 2>/dev/null | head -1 | awk '{print $NF}')"

# Warn if there are uncommitted changes — ArgoCD pulls from git, not local files
if ! git -C "${REPO_ROOT}" diff --quiet HEAD 2>/dev/null; then
  warn "Uncommitted local changes detected."
  warn "  init.sh uses local files; ArgoCD syncs from git (last pushed commit)."
  warn "  Push first if you want ArgoCD to see your changes."
  echo ""
fi

# ── 1. Create or reuse VM ─────────────────────────────────────────────────────
echo "[ 1 ] VM"
VM_STATE=$(multipass info "${VM_NAME}" 2>/dev/null | awk '/^State:/{print $2}' || echo "absent")

case "${VM_STATE}" in
  absent)
    info "Creating VM (${VM_CPUS} vCPU, ${VM_MEMORY} RAM, ${VM_DISK} disk)…"
    multipass launch \
      --name    "${VM_NAME}" \
      --cpus    "${VM_CPUS}" \
      --memory  "${VM_MEMORY}" \
      --disk    "${VM_DISK}"
    ok "VM created"
    ;;
  Stopped|stopped)
    info "Starting stopped VM…"
    multipass start "${VM_NAME}"
    ok "VM started"
    ;;
  Running|running)
    ok "VM already running"
    ;;
  *)
    fail "VM is in unexpected state: ${VM_STATE}"
    ;;
esac

# ── 2. Resolve VM IP ──────────────────────────────────────────────────────────
NODE_IP=$(multipass info "${VM_NAME}" | awk '/^IPv4:/{print $2}' | head -1)
[ -n "${NODE_IP}" ] || fail "Could not read VM IP from multipass info"
ok "Node IP: ${NODE_IP}"

# ── 3. Transfer repo ──────────────────────────────────────────────────────────
echo ""
echo "[ 2 ] Transfer repo"
info "Packing…"
TARBALL="$(mktemp /tmp/infra-XXXXXX.tar.gz)"
# Exclude .git/objects to keep the tarball small; git remote info is preserved
tar -czf "${TARBALL}" -C "${REPO_ROOT}/.." "${REPO_BASENAME}"

info "Transferring to VM…"
multipass transfer "${TARBALL}" "${VM_NAME}:/tmp/infra-src.tar.gz"
rm -f "${TARBALL}"

info "Extracting…"
vm_exec "rm -rf /root/infrastructure && \
  tar -xzf /tmp/infra-src.tar.gz -C /tmp/ && \
  mv /tmp/${REPO_BASENAME} /root/infrastructure"
ok "Repo at /root/infrastructure"

# ── 4. Patch placeholder secrets (local only — never committed) ───────────────
echo ""
echo "[ 3 ] Generate ephemeral secrets"
info "Patching helmrelease.yaml with random ENCRYPTION_KEY / AUTH_SECRET / DB_PASSWORD…"
vm_exec "
  HELMRELEASE=/root/infrastructure/k8s/system/infisical/helmrelease.yaml
  ENC_KEY=\$(openssl rand -hex 32)
  AUTH_KEY=\$(openssl rand -hex 32)
  DB_PASS=\$(openssl rand -base64 24 | tr -d '/=+' | head -c 32)

  # Replace the two REPLACE_ME_32_CHAR_HEX occurrences with different values
  sed -i \"s|ENCRYPTION_KEY: \\\"REPLACE_ME_32_CHAR_HEX\\\"|ENCRYPTION_KEY: \\\"\${ENC_KEY}\\\"|\" \${HELMRELEASE}
  sed -i \"s|AUTH_SECRET: \\\"REPLACE_ME_32_CHAR_HEX\\\"|AUTH_SECRET: \\\"\${AUTH_KEY}\\\"|\" \${HELMRELEASE}

  # Replace both occurrences of REPLACE_DB_PASSWORD (connection URI + auth.password)
  sed -i \"s|REPLACE_DB_PASSWORD|\${DB_PASS}|g\" \${HELMRELEASE}

  echo 'Patched.'
"

info "Patching Let's Encrypt email placeholder…"
vm_exec "sed -i 's|you@example.com|local-test@local.dev|g' \
  /root/infrastructure/k8s/system/cert-manager/cluster-issuers.yaml"

ok "Secrets patched (ephemeral — changes live only inside the VM)"

# ── 5. Run init.sh ────────────────────────────────────────────────────────────
echo ""
echo "[ 4 ] Bootstrap cluster"
info "Running init.sh — this takes ~5 minutes…"
vm_exec "NODE_IP=${NODE_IP} bash /root/infrastructure/setup/init.sh"
ok "init.sh complete"

# ── 6. Self-signed ClusterIssuer for TLS ─────────────────────────────────────
echo ""
echo "[ 5 ] Self-signed TLS (local replacement for Let's Encrypt)"
ISSUER_MANIFEST="$(mktemp /tmp/selfsigned-XXXXXX.yaml)"
cat > "${ISSUER_MANIFEST}" <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
multipass transfer "${ISSUER_MANIFEST}" "${VM_NAME}:/tmp/selfsigned-issuer.yaml"
rm -f "${ISSUER_MANIFEST}"
vm_exec "kubectl apply -f /tmp/selfsigned-issuer.yaml"

# Patch example-app ingress annotation to use self-signed issuer
# (Let's Encrypt HTTP-01 cannot validate private nip.io hostnames)
if vm_kubectl get ingress example-app -n example-app &>/dev/null; then
  vm_kubectl annotate ingress example-app -n example-app \
    cert-manager.io/cluster-issuer=selfsigned --overwrite
  ok "example-app ingress patched → selfsigned issuer"
else
  warn "example-app ingress not synced yet — patch it manually after ArgoCD syncs:"
  warn "  kubectl annotate ingress example-app -n example-app cert-manager.io/cluster-issuer=selfsigned --overwrite"
fi

# ── 7. Stub Infisical Machine Identity credentials ────────────────────────────
echo ""
echo "[ 6 ] Infisical credentials stub"
warn "Creating placeholder infisical-credentials so ESO doesn't error on a missing secret."
warn "Replace with real values to enable secret sync (see cluster-secret-store.yaml)."
vm_kubectl create secret generic infisical-credentials \
  -n external-secrets \
  --from-literal=clientId=local-placeholder \
  --from-literal=clientSecret=local-placeholder \
  --dry-run=client -o yaml | vm_kubectl apply -f -
ok "Stub secret applied"

# ── 8. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "[ 7 ] Verify"
info "Waiting 30s for ArgoCD to complete initial sync…"
sleep 30
vm_exec "NODE_IP=${NODE_IP} bash /root/infrastructure/setup/verify.sh" || true
# verify.sh exits non-zero when checks fail; we continue to print the summary

# ── Summary ───────────────────────────────────────────────────────────────────
ARGOCD_PASSWORD=$(vm_exec \
  "kubectl -n argocd get secret argocd-initial-admin-secret \
   -o jsonpath='{.data.password}' 2>/dev/null | base64 -d" 2>/dev/null \
  || echo "(not available yet)")

echo ""
echo "══════════════════════════════════════════"
echo "  Setup Complete"
echo "══════════════════════════════════════════"
echo ""
echo "  VM:           ${VM_NAME}  (${NODE_IP})"
echo ""
echo "  ArgoCD UI:    http://argocd.${NODE_IP}.nip.io"
echo "  ArgoCD login: admin / ${ARGOCD_PASSWORD}"
echo ""
echo "  example-app:  https://example-app.${NODE_IP}.nip.io"
echo "                (self-signed cert — browser will warn, that's expected)"
echo ""
echo "  Scaffold a new app:"
echo "    APP_NAME=my-api IMAGE=nginx:alpine bash setup/new-app.sh"
echo ""
echo "  Useful commands:"
echo "    multipass shell ${VM_NAME}                      # open a shell in the VM"
echo "    multipass exec ${VM_NAME} -- sudo kubectl get pods -A"
echo "    NODE_IP=${NODE_IP} bash setup/verify.sh         # re-run health check"
echo "    multipass stop ${VM_NAME}                       # pause VM"
echo "    multipass delete ${VM_NAME} --purge             # destroy VM"
echo ""
echo "  Known limitations (local only):"
echo "    ✗ Let's Encrypt — replaced with self-signed (browser cert warning)"
echo "    ✗ Infisical secret sync — needs real Machine Identity credentials"
echo "    ✗ VPN firewall — not applied"
echo ""
