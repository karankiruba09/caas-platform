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

> A customer (`tenant-acme`) is onboarded with one PR. They commit their app to
> Git. Argo CD deploys it to their isolated namespace. It comes up at
> `https://acme-web.<domain>` with automatic TLS, its metrics flow to Grafana
> and its traces to Jaeger, it cannot see or touch any other tenant, and if it
> tries to run a privileged container the platform rejects it — all on open
> source, reproducible from this repo in minutes.

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
│   └── observability/            # OTel Collector + Jaeger (Helm via Argo) + ingress + netpol
├── policies/                     # Kyverno ClusterPolicies (the guardrails)
├── golden-path/
│   └── app/                      # the reusable customer app Helm chart
├── tenants/
│   ├── _template/                # tenant scaffolding (quota, rbac, netpol, AppProject)
│   └── acme/                     # example tenant
├── apps/
│   └── acme-web/                 # example customer app (uses golden-path chart)
├── apps/
│   ├── acme-web/                 # simple sample app (podinfo)
│   └── bookinfo/                 # production-grade meshed multi-service app
└── docs/
    ├── architecture.md           # diagrams + how each layer works
    ├── demo-runbook.md           # the click-by-click stakeholder demo
    └── mesh-app.md               # Istio Bookinfo: mTLS, tracing, canary, HPA
```

## Two sample workloads

- **acme-web** (`apps/acme-web/`) — a single service (podinfo) showing the basic
  golden path: GitOps deploy → URL + TLS + metrics + traces.
- **bookinfo** (`apps/bookinfo/`) — a production-grade **multi-service** app in
  the **Istio mesh**: sidecars, STRICT mTLS, distributed tracing (no app
  changes), canary traffic splitting, retries/fault-injection, HPA, and PDB.
  See [`docs/mesh-app.md`](docs/mesh-app.md).

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
   - OTel Collector+Jaeger   - require limits         tenant-acme:
   - (uses existing)         - runAsNonRoot             quota+limitrange
     Prometheus+Grafana      - no privileged            RBAC (tenant-admin)
   - ingress-nginx           - images from Harbor       default-deny netpol
   - cert-manager                                       AppProject (scoped)
                                                          │
                                                          ▼
                                              golden-path app chart:
                                              Deployment+Service
                                                 ├─ Ingress (auto-TLS)
                                                 ├─ OTLP → collector → Jaeger
                                                 └─ ServiceMonitor → Prometheus
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

# 2. Onboard a tenant (writes tenants/<name>/, commit + push → Argo syncs).
./scripts/onboard-tenant.sh acme

# 3. The customer's app (apps/acme-web) syncs automatically once committed.
#    Then run the demo:
```

Follow [`docs/demo-runbook.md`](docs/demo-runbook.md) for the full walkthrough,
including the guardrail-rejection and tenant-isolation demonstrations.

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
