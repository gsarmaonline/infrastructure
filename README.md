# infrastructure

Contains infrastructure-as-code and tooling for managing cloud resources across AWS and DigitalOcean.

## Structure

```
.
├── aws/                    # AWS Terraform modules and manifests
│   ├── modules/
│   │   ├── ec2/            # EC2 instance provisioning
│   │   ├── networking/     # VPC, subnets, security groups
│   │   └── s3/             # S3 bucket
│   └── manifests/
│       ├── common/         # EC2 deployments
│       └── networking/     # Network stack deployments
│
├── digitalocean/           # DigitalOcean Terraform modules and manifests
│   ├── modules/
│   │   ├── droplets/       # Droplet (VM) provisioning
│   │   ├── k8s/            # Managed Kubernetes cluster
│   │   └── networking/     # VPC
│   └── manifests/
│       ├── kafka/          # Kafka droplet
│       ├── k8s/            # Kubernetes cluster
│       └── networking/     # Network stack deployments
│
├── docker-compose/         # Local development stacks
│   ├── kafka/              # Kafka + Kafka Connect
│   ├── mongo-replicaset/   # MongoDB replica set
│   └── prometheus-grafana/ # Prometheus + Grafana monitoring
│
├── setup/                  # Node initialization scripts
│   ├── cloud-init.sh.tpl   # Terraform template: sets env vars, clones repo, calls init.sh
│   ├── init.sh             # Full bootstrap: k3s, ArgoCD, cert-manager, baseline firewall
│   ├── local-setup.sh      # Local dev setup — spins up a Lima VM and bootstraps it
│   ├── lima.yaml           # Lima VM config (Ubuntu 22.04, vzNAT networking)
│   ├── verify.sh           # Post-bootstrap health check (node, ArgoCD, certs)
│   ├── new-app.sh          # Scaffold a new app from the example-app template
│   ├── worker-init.sh      # k3s agent join script for worker nodes
│   └── vpn-firewall.sh     # Baseline + optional VPN-gated firewall rules
│
└── k8s/                    # Kubernetes manifests (synced by ArgoCD)
    ├── system/
    │   ├── argocd/
    │   │   ├── install.yaml        # ArgoCD namespace
    │   │   ├── app-of-apps.yaml    # ArgoCD Application watching k8s/apps/
    │   │   ├── argocd-params.yaml  # Sets ArgoCD server to insecure mode (for Traefik)
    │   │   ├── vpn-middleware.yaml # Traefik IP-allowlist middleware for VPN peers
    │   │   └── ingress.yaml        # ArgoCD UI ingress (VPN-gated, plain HTTP)
    │   └── cert-manager/           # cert-manager + Let's Encrypt ClusterIssuers
    │       ├── application.yaml    # ArgoCD Application (Helm install)
    │       └── cluster-issuers.yaml  # staging + prod ClusterIssuers (HTTP-01 / Traefik)
    └── apps/
        └── example-app/           # Example app (deployment, service, ingress, secret)
```

## Node Setup

### Local development (Lima VM)

Test the full stack locally before deploying to a cloud VM.
Requires macOS 13 (Ventura) or later.

```bash
brew install lima

# Run — creates a VM, bootstraps k3s + ArgoCD, applies a self-signed TLS issuer
bash setup/local-setup.sh

# Optional overrides
VM_NAME=my-test VM_CPUS=4 VM_MEMORY=8GiB VM_DISK=40GiB bash setup/local-setup.sh
```

The script handles everything: VM creation (Ubuntu 22.04, vzNAT networking),
repo transfer, `init.sh`, a self-signed `ClusterIssuer` (replacing Let's Encrypt),
and a health check. ArgoCD UI and example-app URLs are printed at the end.

**Local limitations vs production:**
- TLS uses self-signed certs (browser will warn — expected)
- VPN firewall is not applied

### Server node (cloud)

EC2 instances and DigitalOcean Droplets use `setup/cloud-init.sh.tpl` as `user_data` via Terraform's `templatefile()`. On first boot, cloud-init clones the repo and runs `init.sh`, which fully bootstraps the cluster: k3s, ArgoCD, cert-manager, and baseline firewall rules.

Pass deployment variables to the Terraform module:

| Variable | Default | Description |
|---|---|---|
| `repo_url` | *(required)* | HTTPS git URL to clone on boot |
| `letsencrypt_email` | `you@example.com` | Email for Let's Encrypt notifications |
| `vpn_subnet` | `""` | VPN CIDR to restrict SSH/6443 to VPN peers + expose ArgoCD ingress |

### Verify bootstrap

After `init.sh` completes, run the health-check script to confirm every layer is working:

```bash
bash setup/verify.sh              # auto-detects node IP
NODE_IP=1.2.3.4 bash verify.sh   # explicit override
```

It checks: k3s node Ready → ArgoCD apps Synced/Healthy → cert-manager + ClusterIssuers → all Certificates → patches the `example-app` ingress to `example-app.<NODE_IP>.nip.io`. Ends with an access summary (ArgoCD URL + admin password).

### Worker nodes

Worker nodes run `setup/worker-init.sh`, which joins an existing k3s cluster. Pass `K3S_URL` and `K3S_TOKEN` as environment variables in `user_data`:

```hcl
user_data = templatefile("setup/worker-init.sh", {
  K3S_URL   = "https://<server-ip>:6443"
  K3S_TOKEN = "<token from /var/lib/rancher/k3s/server/node-token>"
})
```

The token is printed by `init.sh` and stored at `/var/lib/rancher/k3s/server/node-token` on the server node.

## Firewall

`vpn-firewall.sh` is always run by `init.sh` and applies these baseline rules unconditionally:

| Port | Access |
|---|---|
| 80, 443 | Public (Traefik ingress) |
| 6443 | Localhost only (k3s API) |
| 22 | Open (or VPN-only when `VPN_SUBNET` is set) |

Re-run at any time to change the posture:

```bash
# Baseline only (SSH open)
bash setup/vpn-firewall.sh

# Restrict SSH + k3s API to VPN peers
VPN_SUBNET=100.64.0.0/10 bash setup/vpn-firewall.sh
```

### Enabling Tailscale (or NordVPN Meshnet)

Both use the `100.64.0.0/10` CGNAT range — no config changes needed when switching between them.

```bash
# 1. Install and connect
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up   # follow the auth URL printed

# 2. Re-run the firewall to restrict SSH + k3s API to VPN peers
VPN_SUBNET=100.64.0.0/10 bash setup/vpn-firewall.sh
```

After step 2, SSH from outside your Tailscale network will be blocked — ensure you are connected before running it.

**To switch VPN providers** (e.g. Tailscale → NordVPN Meshnet): install the new client, run `tailscale up` or `nordvpn meshnet`, uninstall the old one. No firewall or Kubernetes changes needed.

## Kubernetes / GitOps

ArgoCD watches `k8s/apps/` and auto-syncs on every push to `main`. To deploy a new app, use the scaffold script:

```bash
APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest bash setup/new-app.sh

# Optional overrides
APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest PORT=8080 DOMAIN=api.example.com bash setup/new-app.sh
```

This copies `k8s/apps/example-app/` into `k8s/apps/my-api/`, substitutes all names/image/port/domain, and prints the `git add / commit / push` commands to trigger a sync.

**Hostnames and nip.io:** by default the ingress host is `<app-name>.<node-ip>.nip.io`. [nip.io](https://nip.io) is a free wildcard DNS service — any hostname of the form `<label>.<ip>.nip.io` resolves to `<ip>`, so no DNS setup is required. To use a real domain, point its A record at the node IP and pass `DOMAIN=api.example.com` to the scaffold script.

**repoURL:** `init.sh` auto-detects the git remote and patches all `application.yaml` placeholders before applying anything, so no manual edits are needed before the first run.

### ArgoCD UI access

When `VPN_SUBNET` is set, the ArgoCD UI is exposed via Traefik at `http://argocd.<NODE_IP>.nip.io` behind a VPN IP-allowlist middleware.

Without a VPN, access via port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# open https://localhost:8080
```

Get the admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### Private registry images

If your image requires authentication, create an image pull secret in the app namespace before (or after) ArgoCD syncs:

```bash
kubectl create secret docker-registry regcred \
  -n my-api \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat>
```

Then add `imagePullSecrets` to the Deployment in `k8s/apps/my-api/deployment.yaml`:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: regcred
      containers:
        ...
```

## Secret Management

Secrets are plain Kubernetes Secrets stored in etcd. No additional secret-sync operator is required.

Apps consume secrets via `envFrom` in their Deployment (both refs are `optional: true`, so pods start even if the secret doesn't exist yet):

```yaml
envFrom:
  - secretRef:
      name: example-app-secrets
      optional: true
```

Create or update a secret with:

```bash
kubectl create secret generic example-app-secrets -n example-app \
  --from-literal=MY_KEY=value \
  --dry-run=client -o yaml | kubectl apply -f -
```

A placeholder `Secret` (`stringData: {}`) is committed in `k8s/apps/example-app/secret.yaml` so ArgoCD does not show the app as degraded before real values are set.

## TLS / HTTPS

Certificates are managed by [cert-manager](https://cert-manager.io) with Let's Encrypt using HTTP-01 challenges via Traefik. `init.sh` handles the full bootstrap automatically.

**HTTP-01 limitation:** Let's Encrypt's verification servers must reach `http://<domain>/.well-known/acme-challenge/...` from the public internet. VPN-gated ingresses (e.g. ArgoCD) cannot use HTTP-01 — use DNS-01 with a supported DNS provider for those.

### Staging → production

Ingresses start with `cert-manager.io/cluster-issuer: letsencrypt-staging` — staging certs are not trusted by browsers but do not consume rate limits. Once confirmed working, promote to production:

```bash
# Switch the issuer annotation
kubectl annotate ingress <name> -n <namespace> \
  cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite

# Delete the staging cert so cert-manager issues a new prod one
kubectl delete certificate -n <namespace> <name>
```

## Usage

Each manifest directory contains a `vars.tfvars` file for environment-specific values. To deploy:

```bash
cd aws/manifests/common        # or any other manifest directory
terraform init
terraform apply -var-file=vars.tfvars
```
