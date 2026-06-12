# Design Blueprint — Application Onboarding (Tenant / App Team)

**Audience:** Tenant / application teams (the "developers")
**Status:** POC reference design
**Scope:** How an application is designed, secured, and delivered onto the ThinkOn
open-source Kubernetes platform — the *design* and the *compliance model*, not only
the deploy steps.

---

## 1. Purpose & objectives

Let an application team take a real, production-shaped app from **Git commit to
running, secured, observed, and exposed** — without filing platform tickets and
without hand-wiring TLS, mTLS, tracing, metrics, or policy. The platform provides
a **paved road**; the app rides it.

### Non-goals (POC)

- Replacing the app team's CI (image build/test happens upstream; this blueprint
  starts at "an image exists in a registry").
- Multi-cluster / multi-region delivery (single cluster for the POC).

---

## 2. Design principles

| Principle | What it means here |
|---|---|
| **GitOps self-service** | The app's desired state lives in Git; Argo CD syncs it into the tenant namespace. No `kubectl apply` by humans. |
| **Paved road** | Ingress+TLS, mesh mTLS, tracing, metrics, and policy are provided by the platform — the app declares intent, the platform wires the plumbing. |
| **Compliant by construction** | The recommended manifests/chart already satisfy the guardrails (limits, non-root, registry), so "the easy way" is "the compliant way." |
| **Observability is built-in** | Traces and metrics appear without instrumenting the app (mesh sidecars + ServiceMonitor). |
| **Tier-aware design** | Stateless tiers scale; stateful tiers get stable identity + storage; batch runs as Jobs/CronJobs. |
| **Least privilege at the edge** | The app team operates only inside their namespace, under their scoped AppProject/kubeconfig. |

---

## 3. Delivery model

Two supported paths, same GitOps backbone:

| Path | When | Mechanism |
|---|---|---|
| **Golden-path chart** | simple single-service app | `golden-path/app/` Helm chart — supply image + host, get Deployment+Service+Ingress(TLS)+ServiceMonitor+OTLP wiring |
| **Custom kustomize/Helm bundle** | multi-tier / stateful app | the app's own `apps/<name>/` bundle (e.g. WordPress) referenced by one Argo Application |

```
   App team (Git)
        │ commit apps/<name>/ (chart values OR kustomize bundle)
        ▼
   Argo CD  ── reconciles under the tenant's AppProject ──▶ tenant namespace
        │
        ▼  platform auto-applies on top:
   cert-manager (TLS) · Istio (mTLS+traces) · Prometheus (metrics) · Kyverno (policy)
```

---

## 4. The paved road — what the platform provides automatically

| Capability | Provided by | App's responsibility |
|---|---|---|
| Public URL + **TLS** | nginx ingress + cert-manager | declare an `Ingress` with the issuer annotation |
| **mTLS** between services | Istio (sidecar, istio-cni) | be in a mesh-enabled namespace |
| **Distributed tracing** | Istio → OTel Collector → Jaeger | nothing (sidecars emit spans) |
| **Metrics** | Prometheus Operator | emit a `ServiceMonitor` (golden-path chart does this) |
| **Autoscaling** | metrics-server + HPA | declare an `HorizontalPodAutoscaler` |
| **Storage** | Longhorn (RWO + RWX) | declare a `PVC` with `storageClassName: longhorn` |
| **Policy guardrails** | Kyverno (admission) | meet them (see §5) — the chart's defaults already do |
| **Isolation** | tenant NetworkPolicy/quota/RBAC | stay within the namespace |

The design intent: the app team writes *what* it needs (an ingress host, a PVC, an
HPA target), and the platform supplies *how* it's secured, exposed, and observed.

---

## 5. Security & compliance design

An application is admitted only if it satisfies the platform's policies. This is
**not** a review gate — it is enforced at admission, automatically.

### 5.1 What every app must satisfy

| Requirement | Enforced by | How the app meets it |
|---|---|---|
| Resource **requests + limits** on every container | Kyverno `require-resource-limits` (Enforce) | set `resources`; LimitRange also defaults them |
| **Run as non-root** | Kyverno `require-run-as-nonroot` (Enforce) | set `runAsNonRoot: true` (chart default) |
| **No privileged / host namespaces** | Kyverno `disallow-privileged` + Pod Security | don't request them |
| **Approved registry** | Kyverno `restrict-image-registries` (Audit→Enforce) | pull images from the approved Harbor registry |
| **Ingress-only exposure** | quota (`loadbalancers/nodeports=0`) | expose via `Ingress`, not LB/NodePort |

### 5.2 The exception process (designed, not ad-hoc)

Some legitimate workloads need root (e.g. WordPress/Apache). The design provides a
**labelled, auditable opt-out** rather than disabling the policy:

- The platform team labels the namespace `caas.allow-root: "true"`.
- The `require-run-as-nonroot` policy **excludes** namespaces with that label.
- Every *other* tenant still enforces non-root. The exception is explicit, visible
  in Git, and scoped to one namespace.

### 5.3 Defense in depth (app's view)

```
   App pod admission
     ├─ Pod Security (namespace) — baseline/restricted
     ├─ Kyverno — limits / non-root / no-privileged / registry
     ├─ ResourceQuota / LimitRange — consumption caps
     └─ NetworkPolicy — default-deny; only ingress-nginx + monitoring reach it
   Runtime
     └─ Istio STRICT mTLS — east-west traffic mutually authenticated
```

---

## 6. Application architecture patterns

A production app is a set of **tiers**, each mapping to specific Kubernetes
primitives. The POC reference app (WordPress + MySQL) demonstrates all of them:

| Tier | Pattern | Kubernetes primitives | WordPress example |
|---|---|---|---|
| **Web / frontend** | stateless, horizontally scalable | Deployment, HPA, PDB, Service, Ingress | WordPress (2 replicas, RWX content, HPA 2→4) |
| **API** | stateless | Deployment, Service, ConfigMap, Secret | (folded into the web tier here) |
| **Database** | stateful, stable identity | StatefulSet, headless Service, PVC (RWO) | MySQL StatefulSet + Longhorn PVC |
| **Cache** | stateful/ephemeral | Deployment/StatefulSet, Secret | (optional Redis) |
| **Config** | externalised configuration | ConfigMap | my.cnf, php uploads.ini |
| **Secrets** | credentials | Secret (+ Sealed/External in prod) | DB + admin creds |
| **Init** | ordering / readiness | initContainer | wait-for-mysql |
| **Batch** | one-off & scheduled | Job, CronJob | wp-install Job, mysqldump CronJob |
| **Storage** | persistence | PVC, StorageClass (RWO + RWX) | 3 Longhorn volumes |
| **Mesh** | security + telemetry | sidecar, PeerAuthentication, DestinationRule | STRICT mTLS, traces |

Design guidance:
- **Stateless tiers** get replicas + HPA + PDB + rolling updates.
- **Stateful tiers** get a StatefulSet + their own PVC; never share a single
  RWO volume across replicas — use RWX (Longhorn) when replicas must share data.
- **Batch** belongs in Jobs/CronJobs, not in the app's request path.

---

## 7. The "how" — deployment workflow

| Step | App team action | Platform reaction |
|---|---|---|
| 1 | Author manifests/values in `apps/<name>/` (or the golden-path chart) | — |
| 2 | `git commit && git push` | Argo CD detects the change |
| 3 | (Argo auto-syncs under the tenant's AppProject) | resources applied to `tenant-<name>` |
| 4 | — | cert-manager issues TLS; Istio injects sidecars; Prometheus discovers the ServiceMonitor |
| 5 | Open `https://<app>.<domain>` | live, TLS-terminated, mesh-secured |

The app team never ran `kubectl`. They committed intent; the platform delivered a
running, exposed, secured, observed app.

---

## 8. Observability & operations (app's view)

| Signal / op | Where | Notes |
|---|---|---|
| **Traces** | Jaeger (`jaeger.<domain>`) | service-to-service spans from the mesh, no app code |
| **Metrics** | Grafana (`grafana.<domain>`) | mesh + app metrics via Prometheus |
| **Scaling** | `kubectl get hpa` | autoscale on CPU |
| **Backups** | CronJob → PVC | e.g. nightly `mysqldump` |
| **Rollout / rollback** | Git revert → Argo sync | declarative, auditable |

---

## 9. Lifecycle management

```
  Deploy ─▶ Operate ─▶ Update ─▶ Rollback ─▶ Decommission
    │          │          │          │            │
  commit    traces,    edit &     git revert   git rm
  apps/<n>  metrics,   commit     + Argo sync   apps/<n>
            backups    (Argo                     (Argo prunes)
                       rolling
                       update)
```

- **Update:** change the manifest/values, commit — Argo performs a rolling update;
  PDB keeps the service available.
- **Rollback:** `git revert` the change; Argo reconciles back. The desired state is
  always what's in Git.
- **Decommission:** `git rm apps/<name>` → Argo prunes the workloads (data on PVCs
  is retained per the volume's reclaim policy until the PVC is removed).

---

## 10. Roles & responsibilities

| Activity | Platform team | App team |
|---|---|---|
| Provide the paved road (ingress, TLS, mesh, observability, policy) | **Owns** | consumes |
| Author application manifests | reviews/advises | **Owns** |
| Meet the guardrails | sets them | **Owns** compliance |
| Request a root/registry exception | **Approves** (labels ns) | requests, justifies |
| Deploy / update / rollback | — | **Owns** (via GitOps) |
| App-level incident response | platform supports | **Owns** |

---

## 11. Production hardening roadmap

| Area | POC state | Production target |
|---|---|---|
| Secrets | demo Secret in Git | Sealed Secrets / External Secrets / Vault |
| Database | single MySQL StatefulSet | replicated DB operator (e.g. Percona/MySQL Operator), PITR backups |
| Images | public registries (Audit) | mirror to Harbor, sign (Cosign), verify at admission |
| Progressive delivery | rolling update | canary / blue-green (Argo Rollouts + Istio traffic split) |
| Backups | mysqldump to PVC | off-cluster object storage + restore drills (Velero) |
| Config drift | Argo selfHeal | + policy reporting + alerting on drift |

---

## 12. Summary

An application is **a set of tiers expressed as Kubernetes manifests in Git**,
delivered through a per-tenant GitOps project onto a paved road that supplies TLS,
mesh security, observability, and policy automatically. The app team owns *what*
to run and *how it's architected*; the platform owns *how it's secured, exposed,
and observed*. See [`fullstack-app.md`](fullstack-app.md) for the worked reference
(WordPress) and runbook.
