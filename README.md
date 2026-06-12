# caas-platform

Open-source Container-as-a-Service demo for a Rancher-managed Kubernetes
cluster. The repo is intentionally split into three demo areas:

```text
caas-platform/
├── platform-onboarding/   # shared platform services: Argo CD, Istio, OTel, Jaeger
├── tenant-onboarding/     # tenant access, quota, RBAC, network, policy, kubeconfig
└── demo/                  # tenant-owned WordPress + MySQL app and the portal front-door
```

The story is simple:

1. The platform team bootstraps shared cluster services.
2. The platform team onboards an isolated tenant with one command.
3. The tenant team ships the demo application through GitOps.

## 1. Platform Onboarding

Installs Argo CD and lets Argo reconcile the shared services used by everyone:
metrics-server, Kyverno, Istio, OpenTelemetry Collector, Jaeger, and the Argo CD
ingress.

```bash
./platform-onboarding/bootstrap.sh
```

For a different repo/domain/issuer, retarget first:

```bash
REPO_URL=https://git.example.com/team/platform-engineering.git \
BASE_DOMAIN=apps.example.com \
CLUSTER_ISSUER=letsencrypt-prod \
./platform-onboarding/set-cluster.sh
```

Details: [platform-onboarding/README.md](platform-onboarding/README.md)

## 2. Tenant Onboarding

Creates the tenant boundary and access model: namespace, Pod Security labels,
ResourceQuota, LimitRange, RBAC, default-deny NetworkPolicy, AppProject, Kyverno
guardrails, and a namespace-scoped kubeconfig.

```bash
./tenant-onboarding/onboard-tenant.sh wordpress --mesh --allow-root
```

Clean removal is the inverse operation:

```bash
./tenant-onboarding/offboard-tenant.sh wordpress
```

Details: [tenant-onboarding/README.md](tenant-onboarding/README.md)

## 3. Demo

The tenant-owned workload is a full-stack WordPress + MySQL app, plus the branded
**portal** front-door — both in the one tenant namespace (no separate namespace
for the portal). One Argo Application points at `demo/` and deploys web, database,
storage, jobs, Ingress/TLS, HPA, PDB, mesh config, the portal, and observability
wiring.

Details: [demo/README.md](demo/README.md)

## Expected Cluster Prereqs

The demo assumes these already exist on the Rancher-managed cluster:

- ingress-nginx with `IngressClass` `nginx`
- cert-manager with `ClusterIssuer` `letsencrypt-cloudflare`
- Longhorn as the default storage provider
- kube-prometheus-stack / Prometheus Operator CRDs
- Harbor or an approved image registry matching the Kyverno registry policy

## Validation

Useful local checks:

```bash
bash -n platform-onboarding/*.sh tenant-onboarding/*.sh
kubectl apply --dry-run=client --validate=false \
  -f platform-onboarding/argocd/root-app.yaml \
  -f platform-onboarding/argocd/projects \
  -f platform-onboarding/argocd/apps \
  -f tenant-onboarding/policies \
  -f tenant-onboarding/tenants/wordpress
kubectl kustomize demo >/tmp/caas-demo.yaml
kubectl apply --dry-run=client --validate=false -f /tmp/caas-demo.yaml
```
