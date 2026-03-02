#!/bin/bash
# VPN-gated firewall configuration
#
# Restricts SSH and the k3s API server to VPN peers only.
# Public ports (80/443) remain open for Traefik ingress.
#
# Works with any VPN that assigns addresses from 100.64.0.0/10 (RFC 6598 CGNAT):
#   - NordVPN Meshnet
#   - Tailscale
#
# Switching providers: install the new VPN client, uninstall the old one.
# No changes to this script or to any Kubernetes manifests are required.
#
# Usage:
#   sudo bash vpn-firewall.sh
#   VPN_SUBNET=100.64.0.0/10 sudo bash vpn-firewall.sh

set -euo pipefail

VPN_SUBNET="${VPN_SUBNET:-100.64.0.0/10}"

echo "========================================"
echo "  VPN-gated firewall setup"
echo "  VPN subnet: ${VPN_SUBNET}"
echo "========================================"

# ── Install ufw if missing ────────────────────────────────────────────────────
if ! command -v ufw &>/dev/null; then
  echo "Installing ufw..."
  apt-get update -qq
  apt-get install -y -qq ufw
fi

# ── Reset to a clean state ────────────────────────────────────────────────────
echo "Resetting ufw rules..."
ufw --force reset

# ── Default policy ────────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing

# ── SSH (port 22): VPN peers only ────────────────────────────────────────────
echo "Allowing SSH from ${VPN_SUBNET}..."
ufw allow from "${VPN_SUBNET}" to any port 22 proto tcp comment "SSH: VPN peers only"

# ── k3s API (port 6443): VPN peers + localhost ────────────────────────────────
echo "Allowing k3s API from ${VPN_SUBNET} and localhost..."
ufw allow from "${VPN_SUBNET}" to any port 6443 proto tcp comment "k3s API: VPN peers"
ufw allow from 127.0.0.1       to any port 6443 proto tcp comment "k3s API: localhost"

# ── Traefik ingress (80/443): public ─────────────────────────────────────────
echo "Allowing HTTP/HTTPS from anywhere (public ingress)..."
ufw allow 80/tcp  comment "Traefik HTTP"
ufw allow 443/tcp comment "Traefik HTTPS"

# ── Enable ───────────────────────────────────────────────────────────────────
echo "Enabling ufw..."
ufw --force enable

echo ""
ufw status verbose
echo ""
echo "========================================"
echo "  Firewall active."
echo ""
echo "  To switch VPN providers (e.g. NordVPN → Tailscale):"
echo "    1. curl -fsSL https://tailscale.com/install.sh | sh"
echo "    2. tailscale up"
echo "    3. Uninstall NordVPN."
echo "    No firewall or Kubernetes changes needed —"
echo "    both providers use ${VPN_SUBNET}."
echo "========================================"
