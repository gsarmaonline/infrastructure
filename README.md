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
    │   └── argocd/
    │       ├── install.yaml        # ArgoCD namespace
    │       └── app-of-apps.yaml    # ArgoCD Application watching k8s/apps/
    └── apps/
        └── example-app/           # Example app (deployment, service, ingress)
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

## Usage

Each manifest directory contains a `vars.tfvars` file for environment-specific values. To deploy:

```bash
cd aws/manifests/common        # or any other manifest directory
terraform init
terraform apply -var-file=vars.tfvars
```

# todo
- vpn based ssh access
- secret manager
