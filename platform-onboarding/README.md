# Platform Onboarding

This folder is owned by the platform team. It bootstraps and reconciles the
shared cluster services every tenant uses.

## What Lives Here

- `bootstrap.sh` installs Argo CD and applies the root app-of-apps.
- `set-cluster.sh` retargets repo URL, base domain, and ClusterIssuer values.
- `argocd/` contains the root app, child apps, and platform AppProject.
- `services/` contains shared in-cluster services:
  - Argo CD ingress
  - Istio mesh config
  - OpenTelemetry / Jaeger extras

## Bootstrap

```bash
./platform-onboarding/bootstrap.sh
```

Argo CD then reconciles:

1. platform projects
2. shared platform services
3. tenant guardrails from `tenant-onboarding/policies`
4. tenant manifests from `tenant-onboarding/tenants`
5. the demo (WordPress app + portal) from `demo`

## Existing Cluster Migration

If this repo was already bootstrapped before the folder simplification, re-apply
the root app once so Argo CD watches the new child-app path:

```bash
kubectl apply -f platform-onboarding/argocd/root-app.yaml
```

After that, Argo reconciles the new layout normally.

## Retargeting

Run this before bootstrapping a fork or a new cluster:

```bash
REPO_URL=https://git.example.com/team/platform-engineering.git \
BASE_DOMAIN=apps.example.com \
CLUSTER_ISSUER=letsencrypt-prod \
./platform-onboarding/set-cluster.sh
```

Commit and push the retargeted files before running `bootstrap.sh`; Argo reads
from Git, not from the local working copy.
