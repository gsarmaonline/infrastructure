#!/bin/bash
# k3s agent (worker) node initialization script
# Joins an existing k3s server node.
#
# Required environment variables (set in Terraform user_data):
#   K3S_URL   – e.g. https://10.0.0.1:6443
#   K3S_TOKEN – contents of /var/lib/rancher/k3s/server/node-token on the server

set -euo pipefail

: "${K3S_URL:?K3S_URL must be set to the server URL (e.g. https://<server-ip>:6443)}"
: "${K3S_TOKEN:?K3S_TOKEN must be set to the server node token}"

echo "Starting k3s agent setup..."
echo "Joining server at ${K3S_URL}"

curl -sfL https://get.k3s.io | \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -s - agent

echo "k3s agent setup complete. Node has joined the cluster."
echo "On the server node, run: kubectl get nodes"
