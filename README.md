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
│   ├── init.sh             # k3s server install + ArgoCD bootstrap (runs via user_data)
│   └── worker-init.sh      # k3s agent join script for worker nodes
│
└── k8s/                    # Kubernetes manifests (synced by ArgoCD)
    ├── system/
    │   ├── argocd/
    │   │   ├── install.yaml        # ArgoCD namespace
    │   │   └── app-of-apps.yaml    # ArgoCD Application watching k8s/apps/
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

### Server node
All EC2 instances and DigitalOcean Droplets run `setup/init.sh` on first boot via `user_data` (cloud-init). This installs k3s in server mode and bootstraps ArgoCD.

### Worker nodes
Worker nodes run `setup/worker-init.sh`, which joins an existing k3s cluster. Pass `K3S_URL` and `K3S_TOKEN` as environment variables in `user_data`:

```hcl
user_data = templatefile("setup/worker-init.sh", {
  K3S_URL   = "https://<server-ip>:6443"
  K3S_TOKEN = "<token from /var/lib/rancher/k3s/server/node-token>"
})
```

## Kubernetes / GitOps

ArgoCD watches `k8s/apps/` and auto-syncs on every push to `main`. To deploy a new app:

1. Create `k8s/apps/<your-app>/` with `deployment.yaml`, `service.yaml`, `ingress.yaml`
2. Add an `application.yaml` pointing ArgoCD at that path (copy from `example-app/`)
3. Push — ArgoCD syncs within 3 minutes (or instantly via webhook)

Each app is routed by hostname via Traefik (k3s built-in). Set a unique `host:` in each app's `ingress.yaml` and point the subdomain's DNS A record at the node IP.

**Before first use:** update `repoURL` in `k8s/system/argocd/app-of-apps.yaml` and each `application.yaml` to point at this repo.

## Secret Management

Secrets are managed with [External Secrets Operator](https://external-secrets.io) (ESO) pulling from a self-hosted [Infisical](https://infisical.com) instance running inside the cluster.

**Secret scopes:**
- **Global secrets** — a `ClusterExternalSecret` in `k8s/apps/_global/` injects a `global-secrets` Kubernetes Secret into every namespace labelled `secrets.infisical.com/inject-global: "true"`.
- **App-specific secrets** — an `ExternalSecret` per app namespace (e.g. `k8s/apps/example-app/external-secret.yaml`) injects only that app's secrets.

**Bootstrap steps (one-time):**

```bash
# 1. Apply ESO and Infisical system apps (edit repoURL TODOs first)
kubectl apply -f k8s/system/external-secrets/application.yaml
kubectl apply -f k8s/system/infisical/application.yaml

# 2. Fill in ENCRYPTION_KEY, AUTH_SECRET, DB password in helmrelease.yaml, then:
#    Create a Machine Identity in the Infisical UI → Project Settings → Machine Identities
kubectl create secret generic infisical-credentials \
  -n external-secrets \
  --from-literal=clientId=<id> \
  --from-literal=clientSecret=<secret>

# 3. Update projectSlug / envSlug TODOs in cluster-secret-store.yaml

# 4. Opt namespaces into global secrets
kubectl label namespace example-app secrets.infisical.com/inject-global=true
```

Apps consume secrets via `envFrom` in their Deployment — see `k8s/apps/example-app/deployment.yaml` for the pattern.

## Usage

Each manifest directory contains a `vars.tfvars` file for environment-specific values. To deploy:

```bash
cd aws/manifests/common        # or any other manifest directory
terraform init
terraform apply -var-file=vars.tfvars
```

# todo
- vpn based ssh access
