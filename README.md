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
│   ├── init.sh             # Full bootstrap: k3s, ArgoCD, cert-manager, ESO + Infisical
│   ├── local-setup.sh      # Local dev setup — spins up a Lima VM and bootstraps it
│   ├── lima.yaml           # Lima VM config (Ubuntu 22.04, vzNAT networking)
│   ├── verify.sh           # Post-bootstrap health check (node, ArgoCD, certs, ESO)
│   ├── new-app.sh          # Scaffold a new app from the example-app template
│   ├── worker-init.sh      # k3s agent join script for worker nodes
│   └── vpn-firewall.sh     # Restricts SSH + k3s API to VPN peers (optional)
│
└── k8s/                    # Kubernetes manifests (synced by ArgoCD)
    ├── system/
    │   ├── argocd/
    │   │   ├── install.yaml        # ArgoCD namespace
    │   │   ├── app-of-apps.yaml    # ArgoCD Application watching k8s/apps/
    │   │   ├── argocd-params.yaml  # Sets ArgoCD server to insecure mode (for Traefik)
    │   │   ├── vpn-middleware.yaml # Traefik IP-allowlist middleware for VPN peers
    │   │   └── ingress.yaml        # ArgoCD UI ingress (VPN-gated, plain HTTP)
    │   ├── cert-manager/           # cert-manager + Let's Encrypt ClusterIssuers
    │   │   ├── application.yaml    # ArgoCD Application (Helm install)
    │   │   └── cluster-issuers.yaml  # staging + prod ClusterIssuers (HTTP-01 / Traefik)
    │   ├── external-secrets/       # External Secrets Operator (ESO)
    │   │   ├── application.yaml    # ArgoCD Application (Helm install)
    │   │   └── install.yaml        # ESO namespace
    │   └── infisical/              # Self-hosted Infisical secret manager
    │       ├── application.yaml    # Parent ArgoCD Application (syncs directory)
    │       ├── namespace.yaml      # Infisical namespace
    │       ├── helmrelease.yaml    # Nested ArgoCD App: Infisical Helm chart + Postgres + Redis
    │       └── cluster-secret-store.yaml  # ESO ClusterSecretStore → Infisical
    └── apps/
        ├── _global/                # Global secrets injected into every opted-in namespace
        │   ├── application.yaml    # ArgoCD Application
        │   └── cluster-external-secret.yaml
        └── example-app/           # Example app (deployment, service, ingress, secrets)
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
VM_NAME=my-test VM_CPUS=4 VM_MEMORY=8GiB bash setup/local-setup.sh
```

The script handles everything: VM creation (Ubuntu 22.04, vzNAT networking),
repo transfer, ephemeral secret generation, `init.sh`, a self-signed
`ClusterIssuer` (replacing Let's Encrypt), and a health check. ArgoCD UI and
example-app URLs are printed at the end.

**Local limitations vs production:**
- TLS uses self-signed certs (browser will warn — expected)
- Infisical secret sync needs real Machine Identity credentials to work
- VPN firewall is not applied

### Server node (cloud)
EC2 instances and DigitalOcean Droplets use `setup/cloud-init.sh.tpl` as `user_data` via Terraform's `templatefile()`. On first boot, cloud-init clones the repo and runs `init.sh`, which fully bootstraps the cluster: k3s, ArgoCD, cert-manager, ESO, and Infisical (including bootstrap secrets).

Pass deployment variables to the Terraform module:

| Variable | Default | Description |
|---|---|---|
| `repo_url` | *(required)* | HTTPS git URL to clone on boot |
| `letsencrypt_email` | `you@example.com` | Email for Let's Encrypt notifications |
| `vpn_subnet` | `""` | VPN CIDR to enable firewall + ArgoCD ingress |
| `infisical_client_id` | `placeholder` | Machine Identity client ID |
| `infisical_client_secret` | `placeholder` | Machine Identity client secret |
| `encryption_key` | `""` | Infisical ENCRYPTION_KEY (auto-generated if empty) |
| `auth_secret` | `""` | Infisical AUTH_SECRET (auto-generated if empty) |

### Verify bootstrap

After `init.sh` completes, run the health-check script to confirm every layer is working:

```bash
bash setup/verify.sh              # auto-detects node IP
NODE_IP=1.2.3.4 bash verify.sh   # explicit override
```

It checks: k3s node Ready → ArgoCD apps Synced/Healthy → cert-manager + ClusterIssuers → ESO + ClusterSecretStore → all Certificates → patches the `example-app` ingress to `example-app.<NODE_IP>.nip.io`. Ends with an access summary (ArgoCD URL + admin password).

### Worker nodes
Worker nodes run `setup/worker-init.sh`, which joins an existing k3s cluster. Pass `K3S_URL` and `K3S_TOKEN` as environment variables in `user_data`:

```hcl
user_data = templatefile("setup/worker-init.sh", {
  K3S_URL   = "https://<server-ip>:6443"
  K3S_TOKEN = "<token from /var/lib/rancher/k3s/server/node-token>"
})
```

## Kubernetes / GitOps

ArgoCD watches `k8s/apps/` and auto-syncs on every push to `main`. To deploy a new app, use the scaffold script:

```bash
APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest bash setup/new-app.sh
# Optional overrides: PORT=8080  DOMAIN=api.example.com
```

This copies `k8s/apps/example-app/` into `k8s/apps/my-api/`, substitutes all names/image/port/domain, and prints the `git add / commit / push` commands to trigger a sync.

Each app is routed by hostname via Traefik (k3s built-in). By default the ingress host is set to `<app-name>.<node-ip>.nip.io` (no DNS setup required). Point a custom subdomain's A record at the node IP and pass it as `DOMAIN=` to use a real domain instead.

**repoURL:** `init.sh` auto-detects the git remote and patches all `application.yaml` placeholders before applying anything, so no manual edits are needed before the first run.

## Secret Management

Secrets are managed with [External Secrets Operator](https://external-secrets.io) (ESO) pulling from a self-hosted [Infisical](https://infisical.com) instance running inside the cluster.

**Secret scopes:**
- **Global secrets** — a `ClusterExternalSecret` in `k8s/apps/_global/` injects a `global-secrets` Kubernetes Secret into every namespace labelled `secrets.infisical.com/inject-global: "true"`.
- **App-specific secrets** — an `ExternalSecret` per app namespace (e.g. `k8s/apps/example-app/external-secret.yaml`) injects only that app's secrets.

**Bootstrap steps (one-time):**

`init.sh` (and therefore `local-setup.sh` + cloud deployments) automatically handles steps 1–2. The remaining steps are one-time manual configuration:

```bash
# 1–2. Handled automatically by init.sh:
#   - ESO + Infisical Applications applied to ArgoCD
#   - infisical-secrets (ENCRYPTION_KEY, AUTH_SECRET) created
#   - infisical-credentials created (placeholder or real values from env)

# 3. Create a Machine Identity in the Infisical UI → Project Settings → Machine Identities
#    Then pass the credentials as Terraform variables (cloud) or set env vars (local).

# 4. Update projectSlug / environmentSlug TODOs in cluster-secret-store.yaml and commit.

# 5. Opt namespaces into global secrets
kubectl label namespace example-app secrets.infisical.com/inject-global=true
```

Apps consume secrets via `envFrom` in their Deployment — see `k8s/apps/example-app/deployment.yaml` for the pattern.

## TLS / HTTPS

Certificates are managed by [cert-manager](https://cert-manager.io) with Let's Encrypt using HTTP-01 challenges via Traefik.

**HTTP-01 limitation:** Let's Encrypt's verification servers must reach `http://<domain>/.well-known/acme-challenge/...` from the public internet. VPN-gated Ingresses (e.g., ArgoCD) cannot use HTTP-01 — use DNS-01 with a supported DNS provider for those.

**Bootstrap steps (one-time):**

```bash
# 1. Apply the cert-manager Application and wait for pods
kubectl apply -f k8s/system/cert-manager/application.yaml
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=180s

# 2. Apply ClusterIssuers (update your email in cluster-issuers.yaml first)
kubectl apply -f k8s/system/cert-manager/cluster-issuers.yaml

# 3. Verify
kubectl get clusterissuers
```

**Staging → production workflow:**
1. Ingresses start with `cert-manager.io/cluster-issuer: "letsencrypt-staging"` — staging certs are not trusted by browsers but do not consume rate limits.
2. Once a staging cert is confirmed issued (`kubectl describe certificate -n <ns> <name>`), change the annotation to `letsencrypt-prod` and delete the staging Certificate:
   ```bash
   kubectl delete certificate -n <namespace> <name>
   ```

## Usage

Each manifest directory contains a `vars.tfvars` file for environment-specific values. To deploy:

```bash
cd aws/manifests/common        # or any other manifest directory
terraform init
terraform apply -var-file=vars.tfvars
```

# todo
