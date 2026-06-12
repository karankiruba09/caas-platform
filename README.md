# caas-platform — Open-Source Container-as-a-Service POC

A proof-of-concept **Container-as-a-Service (CaaS)** platform built entirely on
open source, on a Rancher-managed Kubernetes cluster. It demonstrates the full
**golden path**: a customer is onboarded as an isolated tenant, deploys their
own container through **GitOps**, and automatically gets a public URL with TLS,
built-in observability, storage, and policy guardrails — with the platform team
never touching the workload.

> This repository is the **GitOps source of truth**. Argo CD watches it and
> reconciles the cluster to match. To change the platform, change the repo.

---

## The story this POC tells

> A customer (`tenant-wordpress`) is onboarded with one PR, then commits a
> full-stack application (web + database + storage + batch jobs) to Git. Argo CD
> deploys the whole stack to their isolated namespace. It comes up at
> `https://wordpress.<domain>` with automatic TLS, mesh mTLS between tiers,
> distributed traces in Jaeger and metrics in Grafana, autoscaling and backups —
> and the author never wired any of that. All open source, reproducible from this
> repo in minutes.

---

## Open-source building blocks

| Capability | Component | Role |
|---|---|---|
| Cluster management | **Rancher** | Multi-cluster, tenant projects, RBAC UI |
| Image registry / supply chain | **Harbor** | The only registry images may come from |
| Ingress + routing | **ingress-nginx** | Single shared entrypoint, host-based routing |
| TLS automation | **cert-manager** | Per-host Let's Encrypt certs, zero manual steps |
| Storage | **Longhorn** | Default StorageClass for tenant PVCs |
| Metrics + dashboards | **kube-prometheus-stack** | Prometheus Operator + Grafana |
| Traces | **OpenTelemetry Collector + Jaeger** | Platform-wide tracing backend |
| Self-service delivery | **Argo CD** | GitOps engine; customers deploy via Git |
| Policy guardrails | **Kyverno** | Enforce limits, non-root, no-privileged, registry |
| Service mesh | **Istio** (+ istio-cni) | Sidecars: mTLS, traffic management, mesh telemetry |
| Autoscaling metrics | **metrics-server** | Resource-metrics API for HPA and `kubectl top` |
| Tenancy | native K8s | Namespace + ResourceQuota + LimitRange + RBAC + NetworkPolicy |

---

## Repository layout

```
caas-platform/
├── bootstrap.sh                  # ⭐ install Argo CD + apply the app-of-apps
├── scripts/
│   ├── onboard-tenant.sh         # generate a new tenant from the template
│   └── retire-otel-demo.sh       # decommission the old heavy otel-demo
├── argocd/
│   ├── root-app.yaml             # app-of-apps: Argo manages everything below
│   ├── projects/                 # AppProjects (platform vs tenants)
│   └── apps/                     # child Applications (kyverno, observability, policies, tenants)
├── platform/
│   ├── kyverno/                  # Kyverno install (Helm via Argo)
│   ├── istio/                    # mesh-wide Istio config (tracing Telemetry)
│   ├── argocd-ingress/           # Argo CD UI ingress
│   └── observability/            # OTel Collector + Jaeger (Helm via Argo) + ingress + netpol
├── policies/                     # Kyverno ClusterPolicies (the guardrails)
├── golden-path/
│   └── app/                      # reusable Helm chart for simple single-service apps
├── tenants/
│   ├── _template/                # tenant scaffolding (quota, rbac, netpol, AppProject)
│   └── wordpress/                # the application's tenant (mesh-enabled)
├── apps/
│   └── wordpress/                # THE full-stack app (web + db + storage + jobs + mesh)
└── docs/
    ├── architecture.md           # diagrams + how each layer works
    ├── platform-onboarding.md    # PLATFORM TEAM: one-step tenant onboarding + kubeconfig
    ├── fullstack-app.md          # TENANT/APP TEAM: the WordPress full-stack app journey
    └── demo-runbook.md           # platform demo: onboarding, guardrails, isolation
```

## Two journeys, two audiences

The POC serves two teams that will operate independently:

| Journey | Audience | What it is | Guide |
|---|---|---|---|
| **Onboard a tenant** | platform team ("landlord") | One command provisions an isolated, guard-railed tenant and issues a **namespace-scoped kubeconfig** to hand over | [`docs/platform-onboarding.md`](docs/platform-onboarding.md) |
| **Deploy an application** | tenant / app team | A full-stack app (web+db+storage+jobs) deployed via GitOps, with TLS/mesh/observability/policy auto-applied | [`docs/fullstack-app.md`](docs/fullstack-app.md) |

```bash
# Platform team — onboard tenant "x" in one step (provision + scoped kubeconfig):
./scripts/onboard-tenant.sh x
#   → tenant-x with quota, limits, RBAC, NetworkPolicy, PodSecurity, AppProject,
#     Kyverno enforcement, and out/tenant-x.kubeconfig (works only in tenant-x).
```

## The application

One **full-stack application** is the payload of this POC — **WordPress + MySQL**
running in the Istio mesh. It deliberately exercises (almost) the entire
Kubernetes surface — StatefulSet, RWO + RWX persistent volumes (Longhorn),
Secrets, ConfigMaps, init containers, a Job and a CronJob, HPA, PDB, Ingress+TLS,
mesh mTLS + distributed tracing — and the whole stack deploys from **one Argo
Application / one commit**, with the platform auto-applying TLS, mTLS, tracing,
metrics, and policy. See [`docs/fullstack-app.md`](docs/fullstack-app.md).

> The `golden-path/` Helm chart remains as the easy path for *simple*
> single-service apps (image + host → URL+TLS+metrics+traces); the full-stack app
> ships its own kustomize bundle because it is multi-tier.

---

## Architecture at a glance

```
   Customer (Git)                          Platform team (Git)
        │ commit app                            │ onboard tenant (PR)
        ▼                                       ▼
 ┌──────────────────────────── Argo CD (GitOps) ────────────────────────────┐
 │  reconciles this repo → cluster: platform components, policies, tenants   │
 └───────────┬───────────────────────┬───────────────────────┬──────────────┘
             ▼                        ▼                        ▼
   Platform services         Guardrails (Kyverno)     Tenant namespaces
   - OTel Collector+Jaeger   - require limits         tenant-wordpress:
   - Prometheus+Grafana      - runAsNonRoot             quota+limitrange
   - Istio (mesh, mTLS)      - no privileged            RBAC (tenant-admin)
   - ingress-nginx           - images from Harbor       default-deny netpol
   - cert-manager            - (caas.allow-root         AppProject (scoped)
   - metrics-server            opt-out per ns)            │
                                                          ▼
                                              full-stack app (one commit):
                                              WordPress + MySQL StatefulSet
                                                 ├─ Ingress (auto-TLS)
                                                 ├─ Longhorn PVCs (RWO+RWX)
                                                 ├─ mesh mTLS + OTLP → Jaeger
                                                 ├─ Job + CronJob (install/backup)
                                                 └─ HPA + PDB
```

Full detail and the request path are in [`docs/architecture.md`](docs/architecture.md).

---

## Quick start

> Prereqs already on the cluster: ingress-nginx, cert-manager (+ a ClusterIssuer),
> kube-prometheus-stack (with Prometheus Operator), Longhorn, and external DNS
> `*.<BASE_DOMAIN>` → the ingress entrypoint. `kubectl`, `helm`, `git` locally.

```bash
# 1. Install Argo CD and hand it this repo (app-of-apps). Comes up in minutes.
BASE_DOMAIN=apps.k8-cmb1.gcloud.ca ./bootstrap.sh

# 2. The application (tenant-wordpress + apps/wordpress) is already in the repo,
#    so Argo brings up the whole full-stack app automatically.
#    To onboard a NEW simple tenant from the template:
./scripts/onboard-tenant.sh <name>
```

The full-stack app: [`docs/fullstack-app.md`](docs/fullstack-app.md).
Platform demos (onboarding, guardrail-rejection, tenant-isolation):
[`docs/demo-runbook.md`](docs/demo-runbook.md).

---

## Design choices

- **GitOps over click-ops.** Every change is a commit; the cluster is a
  reconciliation of this repo. Auditable, reviewable, reproducible.
- **App-of-apps.** A single root Argo Application installs everything else, so
  one `bootstrap.sh` brings the whole platform up.
- **Golden path, not golden cage.** The reusable chart makes the *easy* way the
  *right* way (TLS, observability, limits) but a tenant can still bring custom
  manifests within their AppProject's guardrails.
- **Defense in depth on tenancy.** Namespace + RBAC + ResourceQuota +
  LimitRange + default-deny NetworkPolicy + Kyverno policies + Argo AppProject —
  no single control is the only thing standing between tenants.
- **Reuse what exists.** Metrics ride the cluster's existing
  kube-prometheus-stack; only the trace backend (OTel + Jaeger) is added.
