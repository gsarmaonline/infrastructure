#!/bin/bash
# Firewall configuration
#
# Always applies baseline rules: deny incoming, allow 80/443, restrict 6443 to localhost.
# If VPN_SUBNET is set, SSH and k3s API are also allowed from VPN peers only.
# Without VPN_SUBNET, SSH is open from anywhere (restrict manually if desired).
#
# Works with any VPN that assigns addresses from 100.64.0.0/10 (RFC 6598 CGNAT):
#   - NordVPN Meshnet
#   - Tailscale
#
# Usage:
#   sudo bash vpn-firewall.sh
#   VPN_SUBNET=100.64.0.0/10 sudo bash vpn-firewall.sh

set -euo pipefail

# ── Install ufw if missing ────────────────────────────────────────────────────
if ! command -v ufw &>/dev/null; then
  echo "Installing ufw..."
  apt-get update -qq
  apt-get install -y -qq ufw
fi

# ── Baseline rules (always applied) ──────────────────────────────────────────
echo "Resetting ufw rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Public web traffic (Traefik)
ufw allow 80/tcp  comment "Traefik HTTP"
ufw allow 443/tcp comment "Traefik HTTPS"

# k3s API: localhost only (never expose to public internet)
ufw allow from 127.0.0.1 to any port 6443 proto tcp comment "k3s API: localhost"

if [ -n "${VPN_SUBNET:-}" ]; then
  echo "VPN_SUBNET=${VPN_SUBNET} — restricting SSH and k3s API to VPN peers."
  # SSH + k3s API: VPN peers only
  ufw allow from "${VPN_SUBNET}" to any port 22   proto tcp comment "SSH: VPN peers only"
  ufw allow from "${VPN_SUBNET}" to any port 6443 proto tcp comment "k3s API: VPN peers"
else
  echo "No VPN_SUBNET set — allowing SSH from anywhere (restrict manually if desired)."
  ufw allow 22/tcp comment "SSH: open"
fi

# ── Enable ───────────────────────────────────────────────────────────────────
echo "Enabling ufw..."
ufw --force enable

echo ""
ufw status verbose
echo ""
echo "========================================"
echo "  Firewall active."
echo "========================================"
