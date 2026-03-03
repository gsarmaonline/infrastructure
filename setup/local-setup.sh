#!/bin/bash
# Bootstrap a local k3s cluster inside a Lima VM.
# Mirrors the production cloud setup as closely as possible.
#
# Differences from production:
#   - TLS: self-signed ClusterIssuer instead of Let's Encrypt
#   - Infisical credentials: stub values (ESO won't sync real secrets without
#     a real Machine Identity — see README for how to wire that up)
#   - VPN firewall: not applied (no VPN_SUBNET set)
#
# Prerequisites:
#   brew install lima          # macOS 13+ required for vzNAT networking
#
# Usage:
#   bash setup/local-setup.sh
#   VM_NAME=my-test VM_CPUS=4 VM_MEMORY=8GiB bash setup/local-setup.sh
#
# Re-running is safe — if the VM already exists it is reused.

set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"
REPO_BASENAME="$(basename "${REPO_ROOT}")"

VM_NAME="${VM_NAME:-infra-local}"
VM_CPUS="${VM_CPUS:-}"       # overrides lima.yaml cpus if set
VM_MEMORY="${VM_MEMORY:-}"   # overrides lima.yaml memory if set (e.g. 8GiB)
VM_DISK="${VM_DISK:-}"       # overrides lima.yaml disk if set

LIMA_YAML="${SETUP_DIR}/lima.yaml"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  → $*"; }
ok()      { echo "  ✓ $*"; }
warn()    { echo "  ⚠  $*"; }
fail()    { echo "  ✗ $*" >&2; exit 1; }

# Run a command as root inside the VM
vm_exec() { limactl shell "${VM_NAME}" sudo bash -c "$1"; }

# Run kubectl as root inside the VM
vm_kubectl() { limactl shell "${VM_NAME}" sudo kubectl "$@"; }

# ── 0. Check prerequisites ────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  Local Infrastructure Setup (Lima)"
echo "  VM: ${VM_NAME}"
echo "══════════════════════════════════════════"
echo ""

if ! command -v limactl &>/dev/null; then
  fail "limactl not found. Install with: brew install lima"
fi
ok "lima $(limactl --version 2>/dev/null | awk '{print $NF}')"

# vzNAT requires macOS 13+
MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo "0")
if [ "${MACOS_VERSION}" -lt 13 ]; then
  fail "macOS 13 (Ventura) or later required for vzNAT networking. Found: $(sw_vers -productVersion)"
fi

# Warn if there are uncommitted changes — ArgoCD pulls from git, not local files
if ! git -C "${REPO_ROOT}" diff --quiet HEAD 2>/dev/null; then
  warn "Uncommitted local changes detected."
  warn "  init.sh uses local files; ArgoCD syncs from git (last pushed commit)."
  warn "  Push first if you want ArgoCD to see your changes."
  echo ""
fi

# ── 1. Create or reuse VM ─────────────────────────────────────────────────────
echo "[ 1 ] VM"
VM_STATUS=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null \
  | awk "/^${VM_NAME} /{print \$2}" || echo "")

if [ -z "${VM_STATUS}" ]; then
  info "Creating VM from ${LIMA_YAML}…"
  # Build the full arg list in one array (always non-empty, so safe under set -u)
  CREATE_ARGS=(--name "${VM_NAME}")
  [ -n "${VM_CPUS}"   ] && CREATE_ARGS+=(--cpus="${VM_CPUS}")
  [ -n "${VM_MEMORY}" ] && CREATE_ARGS+=(--memory="${VM_MEMORY}")
  [ -n "${VM_DISK}"   ] && CREATE_ARGS+=(--disk="${VM_DISK}")
  CREATE_ARGS+=("${LIMA_YAML}")
  limactl create "${CREATE_ARGS[@]}"
  limactl start "${VM_NAME}"
  ok "VM created and started"
elif [ "${VM_STATUS}" = "Stopped" ]; then
  info "Starting stopped VM…"
  limactl start "${VM_NAME}"
  ok "VM started"
elif [ "${VM_STATUS}" = "Running" ]; then
  ok "VM already running"
else
  fail "VM is in unexpected state: ${VM_STATUS}"
fi

# ── 2. Resolve VM IP ──────────────────────────────────────────────────────────
# vzNAT assigns an IP in the 192.168.105.x range; exclude loopback and link-local
NODE_IP=$(limactl shell "${VM_NAME}" \
  ip -4 addr show | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
  | grep -v '^127\.' | grep -v '^169\.254\.' | head -1)
[ -n "${NODE_IP}" ] || fail "Could not determine VM IP. Is vzNAT networking working?"
ok "Node IP: ${NODE_IP}"

# ── 3. Transfer repo ──────────────────────────────────────────────────────────
echo ""
echo "[ 2 ] Transfer repo"
info "Packing…"
TARBALL="$(mktemp /tmp/infra-XXXXXX.tar.gz)"
tar -czf "${TARBALL}" -C "${REPO_ROOT}/.." "${REPO_BASENAME}"

info "Copying to VM…"
limactl cp "${TARBALL}" "${VM_NAME}:/tmp/infra-src.tar.gz"
rm -f "${TARBALL}"

info "Extracting…"
vm_exec "rm -rf /root/infrastructure && \
  tar -xzf /tmp/infra-src.tar.gz -C /tmp/ && \
  mv /tmp/${REPO_BASENAME} /root/infrastructure"
ok "Repo at /root/infrastructure"

# ── 3. Run init.sh ────────────────────────────────────────────────────────────
echo ""
echo "[ 3 ] Bootstrap cluster"
info "Running init.sh — this takes ~5 minutes…"
vm_exec "NODE_IP=${NODE_IP} \
  LETSENCRYPT_EMAIL=local-test@local.dev \
  INFISICAL_CLIENT_ID=local-placeholder \
  INFISICAL_CLIENT_SECRET=local-placeholder \
  bash /root/infrastructure/setup/init.sh"
ok "init.sh complete"

# ── 4. Self-signed ClusterIssuer for TLS ─────────────────────────────────────
echo ""
echo "[ 4 ] Self-signed TLS (local replacement for Let's Encrypt)"
ISSUER_MANIFEST="$(mktemp /tmp/selfsigned-XXXXXX.yaml)"
cat > "${ISSUER_MANIFEST}" <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
limactl cp "${ISSUER_MANIFEST}" "${VM_NAME}:/tmp/selfsigned-issuer.yaml"
rm -f "${ISSUER_MANIFEST}"
vm_exec "kubectl apply -f /tmp/selfsigned-issuer.yaml"

# Patch example-app ingress to use selfsigned instead of letsencrypt-staging
# (Let's Encrypt HTTP-01 cannot validate private nip.io hostnames)
if vm_kubectl get ingress example-app -n example-app &>/dev/null; then
  vm_kubectl annotate ingress example-app -n example-app \
    cert-manager.io/cluster-issuer=selfsigned --overwrite
  ok "example-app ingress patched → selfsigned issuer"
else
  warn "example-app ingress not synced yet — patch it manually once ArgoCD syncs:"
  warn "  limactl shell ${VM_NAME} sudo kubectl annotate ingress example-app \\"
  warn "    -n example-app cert-manager.io/cluster-issuer=selfsigned --overwrite"
fi

# ── 5. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "[ 5 ] Verify"
info "Waiting 30s for ArgoCD to complete initial sync…"
sleep 30
vm_exec "NODE_IP=${NODE_IP} bash /root/infrastructure/setup/verify.sh" || true

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
echo "    limactl shell ${VM_NAME}                           # open a shell in the VM"
echo "    limactl shell ${VM_NAME} sudo kubectl get pods -A"
echo "    NODE_IP=${NODE_IP} bash setup/verify.sh            # re-run health check"
echo "    limactl stop ${VM_NAME}                            # pause VM"
echo "    limactl delete --force ${VM_NAME}                  # destroy VM"
echo ""
echo "  Known limitations (local only):"
echo "    ✗ Let's Encrypt — replaced with self-signed (browser cert warning)"
echo "    ✗ Infisical secret sync — needs real Machine Identity credentials"
echo "    ✗ VPN firewall — not applied"
echo ""
