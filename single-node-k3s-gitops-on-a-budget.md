---
title: Single-Node Kubernetes GitOps on a Budget
description: >-
  How I built a fully automated k3s + ArgoCD GitOps platform on a single $6/month
  DigitalOcean droplet — with TLS, a firewall, and one command to bootstrap it all.
date: "2026-03-04T00:00:00.000000"
categories: []
keywords: []
slug: >-
  single-node-k3s-gitops-on-a-budget
---

You want GitOps. You don't want to pay $70/month for a managed cluster, operate an etcd
quorum, or maintain a fleet of nodes for a side project or small team. You want to push
to `main` and have your app update itself. This is how I built exactly that — a
fully-automated, single-node Kubernetes platform that goes from a fresh Ubuntu VM to a
running ArgoCD-synced cluster in under ten minutes, with TLS and a locked-down firewall.

---

## The Problem

Managed Kubernetes (EKS, GKE, DOKS) is great when you need multi-zone HA and have the
budget. For everything else — internal tools, staging environments, small production
services — it's overkill. But self-managed Kubernetes has historically meant:

- Hand-rolling kubeadm configs
- Managing etcd backups
- Writing custom bootstrap scripts that bitrot
- No clean local dev story

k3s solves most of that. What it doesn't give you out of the box is GitOps, TLS, secret
management, or a sensible firewall. That's the gap this project fills.

The goal: one command on a fresh VM, everything bootstrapped, ArgoCD watching git, apps
live at `https://<app>.<ip>.nip.io`.

---

## Prerequisites

- A Linux VM (Ubuntu 22.04) with a public IP — DigitalOcean, Hetzner, EC2, anything works
- A GitHub repo (public or private) to store your manifests
- For local dev: macOS 13+ with `brew install lima`
- Basic Kubernetes familiarity (what a Deployment is, what a namespace is)

---

## Technical Decisions

### k3s over kubeadm or managed Kubernetes

k3s is a CNCF-graduated Kubernetes distribution that ships as a single binary. It bundles
Traefik (ingress), CoreDNS, and local-path storage — everything you need for a functional
cluster. Installation is one `curl` command and the node is ready in under a minute.

The trade-off is that it's opinionated: you get Traefik whether you want it or not, and
the single-node model means no HA. That's exactly the trade-off we want here.

### ArgoCD app-of-apps for GitOps

ArgoCD's [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
lets a single root Application discover and manage child Applications by scanning a
directory in git. Any subdirectory under `k8s/apps/` that contains an `application.yaml`
becomes a managed app automatically — no manual ArgoCD registration needed.

```yaml
# k8s/system/argocd/app-of-apps.yaml
spec:
  source:
    path: k8s/apps
    directory:
      recurse: true
      include: '**/application.yaml'   # only pick up app registrations, not workload manifests
  syncPolicy:
    automated:
      prune: true      # remove resources deleted from git
      selfHeal: true   # revert manual changes made in the cluster
```

One subtlety: without `include: '**/application.yaml'`, ArgoCD would try to apply every
YAML file in `k8s/apps/` — including Deployment and Service manifests — and then conflict
with the child apps that own those same resources. The `include` filter keeps the root app
only aware of Application objects.

### Plain Kubernetes Secrets over Infisical + ESO

The original design used [External Secrets Operator](https://external-secrets.io) pulling
from a self-hosted [Infisical](https://infisical.com) instance. After several iterations,
this was scrapped entirely.

The problem: Infisical's Machine Identity authentication uses SRP (Secure Remote Password)
— a challenge-response protocol that can't be scripted without reimplementing the crypto.
Every attempt to automate the `infisical login` step hit this wall. The result was a
bootstrap sequence that required manual intervention at exactly the wrong moment: when
you're trying to bring up a fresh server unattended.

Beyond the auth issue, running Infisical inside the cluster meant managing PostgreSQL,
Redis, and the Infisical pod itself — roughly 2GB of RAM just for secret synchronisation
on a node where that RAM is needed for actual workloads.

The replacement: plain Kubernetes Secrets created with `kubectl`. Apps reference them via
`envFrom` with `optional: true`, so pods start even if the secret hasn't been created yet.

```yaml
envFrom:
  - secretRef:
      name: example-app-secrets
      optional: true
```

This is the right trade-off for a single-node setup. The secrets are in etcd. The threat
model for a single-node cluster where you control the machine is different from a
multi-tenant environment. Zero extra pods, zero extra failure modes.

### Baseline firewall that always runs

The original firewall script only activated when `VPN_SUBNET` was set. That meant servers
deployed without a VPN had port 6443 (k3s API) open to the internet. The fix: unconditional
baseline rules, with VPN restrictions layered on top.

```bash
# Always applied
ufw default deny incoming
ufw allow 80/tcp   # Traefik
ufw allow 443/tcp  # Traefik
ufw allow from 127.0.0.1 to any port 6443  # k3s API: localhost only

# Conditional: restrict SSH to VPN peers
if [ -n "${VPN_SUBNET:-}" ]; then
  ufw allow from "${VPN_SUBNET}" to any port 22
  ufw allow from "${VPN_SUBNET}" to any port 6443
else
  ufw allow 22/tcp  # SSH open (lock down manually if needed)
fi
```

Port 6443 is never exposed to the public internet regardless of VPN configuration. That's
the important invariant — even if you forget to set `VPN_SUBNET`, the API server isn't
reachable from outside.

### nip.io for zero-config DNS

Every ingress hostname uses [nip.io](https://nip.io): a free wildcard DNS service where
`<anything>.<ip>.nip.io` resolves to `<ip>`. This gives you real hostnames (required for
TLS, required for HTTP-01 ACME challenges, required for Traefik's host-based routing)
without touching a DNS zone.

`init.sh` auto-detects the node's public IP from cloud instance metadata (AWS IMDSv1,
DigitalOcean metadata, or `api.ipify.org` as a fallback) and patches ingress hostnames at
bootstrap time.

---

## Implementation

### Phase 1: Bootstrap script (`init.sh`)

The entire server bootstrap is a single idempotent script. Terraform passes it as
`user_data` via `cloud-init.sh.tpl` on first boot; for local dev, `local-setup.sh`
transfers it to a Lima VM and runs it there.

Steps in order:

1. Auto-detect git remote URL, convert SSH to HTTPS, patch `repoURL` placeholders in all `application.yaml` files
2. Auto-detect node public IP from metadata endpoints
3. Install k3s (`curl -sfL https://get.k3s.io | sh -s - server`)
4. Wait for node Ready, then pause 10 seconds for API server internal init
5. Install ArgoCD and wait for `argocd-server` deployment to become available
6. Apply `app-of-apps.yaml` — from this point, ArgoCD manages everything in `k8s/apps/`
7. Apply cert-manager Application and wait for both the controller and webhook deployments
8. Apply ClusterIssuers with the Let's Encrypt email patched in
9. Apply baseline firewall rules

The cert-manager wait step is worth explaining. `kubectl wait --watch` drops the TLS watch
stream on resource-constrained nodes under load. The script uses a poll loop instead:

```bash
for i in $(seq 1 120); do
  READY=$(kubectl get deployment cert-manager -n cert-manager \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  [ "${READY:-0}" -ge 1 ] && break
  sleep 5
done
```

120 iterations × 5 seconds = 10 minutes max wait. The webhook must also be ready before
`ClusterIssuer` CRs can be accepted — cert-manager validates them via webhook, so applying
ClusterIssuers before the webhook is up causes a confusing 503 error.

### Phase 2: GitOps structure

```
k8s/
├── system/          # bootstrapped manually with kubectl apply
│   ├── argocd/      # app-of-apps + ingress + VPN middleware
│   └── cert-manager/
└── apps/            # auto-discovered by app-of-apps
    └── example-app/ # deployment, service, ingress, secret
```

System components (`argocd`, `cert-manager`) are applied once by `init.sh`. Everything
under `k8s/apps/` is discovered and synced by ArgoCD on every push to `main`.

### Phase 3: App scaffold

New apps are scaffolded from the `example-app` template:

```bash
APP_NAME=my-api IMAGE=ghcr.io/org/my-api:latest bash setup/new-app.sh
# Optional: PORT=8080  DOMAIN=api.example.com
```

This copies `k8s/apps/example-app/` into `k8s/apps/my-api/`, substitutes all
names/image/port/domain, and prints the git commands to push and trigger a sync.

The scaffold creates five files: `application.yaml` (ArgoCD Application),
`deployment.yaml`, `service.yaml`, `ingress.yaml`, and `secret.yaml` (empty placeholder).

### Phase 4: Local dev parity

`local-setup.sh` mirrors production in a Lima VM on macOS. The key differences:

- Replaces Let's Encrypt with a self-signed `ClusterIssuer` (HTTP-01 can't validate
  private `192.168.x.x` addresses)
- Skips the VPN firewall (no `VPN_SUBNET` set)
- Transfers the local repo via tarball rather than cloning from git

The transfer approach means you can test uncommitted changes locally. ArgoCD inside the VM
still syncs from git (the pushed commit), but `init.sh` itself runs from the transferred
files — useful for iterating on bootstrap scripts without pushing every change.

---

## How It All Fits Together

```
GitHub repo (main branch)
        │
        │  git push
        ▼
   ArgoCD (app-of-apps)
        │
        │  discovers k8s/apps/**/application.yaml
        ├──► example-app Application
        ├──► my-api Application
        └──► ...
              │
              │  applies manifests to cluster
              ▼
         k3s cluster
              │
              ├── Traefik (ingress, routes by Host header)
              ├── cert-manager (issues Let's Encrypt certs)
              └── app pods (read secrets from etcd via envFrom)
```

Traffic flow for an incoming request:

1. DNS: `my-api.<ip>.nip.io` resolves to the node's public IP
2. UFW: allows port 443, forwards to Traefik
3. Traefik: matches `Host: my-api.<ip>.nip.io`, terminates TLS (cert from cert-manager), proxies to `my-api` Service
4. Pod: reads `my-api-secrets` Secret via `envFrom`

---

## Lessons Learned

**Infisical looked great until it didn't.** SRP authentication is a reasonable security
choice for interactive logins. It's a disaster for automation. The lesson: when evaluating
secret management tools, test the machine-to-machine auth flow first, not the UI.

**`kubectl wait --watch` is unreliable on constrained nodes.** It opens a long-lived TLS
watch stream, which drops silently when the API server is under memory pressure. Polling
with a loop is less elegant but more reliable in practice.

**The firewall baseline matters more than the VPN restriction.** Not running the firewall
at all when `VPN_SUBNET` isn't set was the bigger risk — port 6443 open to the internet
is a real problem. The VPN restriction is a nice-to-have. The baseline deny-incoming is
not.

**The app-of-apps `include` filter prevents a subtle footgun.** Without it, ArgoCD
attempts to own every YAML file in `k8s/apps/`, then conflicts with child apps over the
same resources. The `SharedResourceWarning` is confusing to diagnose.

**A 10-second pause after `node Ready` is necessary.** The k3s node reports Ready before
the API server has fully initialized its internal state. Sending large `kubectl apply`
payloads immediately after Ready causes transient errors that look like cert or auth
problems.

---

## What's Next

- **VPN-gated ArgoCD UI**: when `VPN_SUBNET` is set, `init.sh` exposes ArgoCD via Traefik
  with an IP-allowlist middleware — the infrastructure is there, just not the default.
- **DNS-01 for private ingresses**: HTTP-01 ACME challenges require public internet access.
  Ingresses behind a VPN need DNS-01 with a supported provider (Cloudflare, Route53).
- **Multi-node**: `worker-init.sh` exists and joins additional k3s agents — but the
  storage (local-path) and networking (no CNI overlay) assumptions need revisiting for
  real multi-node setups.

---

## References

- [k3s documentation](https://docs.k3s.io)
- [ArgoCD app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [cert-manager ACME HTTP-01 challenge](https://cert-manager.io/docs/configuration/acme/http01/)
- [nip.io wildcard DNS](https://nip.io)
- [RFC 6598 — Shared Address Space (100.64.0.0/10)](https://datatracker.ietf.org/doc/html/rfc6598)
- [Tailscale install](https://tailscale.com/download/linux)
