# Architecture

How the open-source CaaS platform fits together, layer by layer.

---

## 1. The big picture

```
                              OUTSIDE THE CLUSTER
   Customer app / browser ──DNS(*.BASE_DOMAIN)──▶ HAProxy (public IP)
                                                      │ :443 → NodePort 30443
 ════════════════════════════════════════════════════╪═══════════════════════
   KUBERNETES CLUSTER (Rancher)                       ▼
                                          ingress-nginx (host-based routing)
                                                      │
        ┌─────────────────────────────────┬──────────┴───────────┐
        ▼                                  ▼                      ▼
  wordpress.BASE_DOMAIN            jaeger.BASE_DOMAIN      grafana.BASE_DOMAIN
   (tenant app)                    (platform UI)           (platform UI)
        │                                  ▲                      ▲
        │ traces/metrics                   │ traces               │ metrics
        ▼                                  │                      │
  OTel Collector ──────────────────────▶ Jaeger          kube-prometheus-stack
  (platform-observability ns)                              (monitoring ns)

   CONTROL PLANE (GitOps)
   Argo CD (argocd ns) ── reconciles this repo ──▶ all of the above + tenants
   Kyverno (kyverno ns) ── admission webhook ──▶ allows/denies every pod
```

---

## 2. Layers

### 2.1 Control plane — Argo CD (GitOps)

Argo CD is the engine. A single **root Application** (`argocd/root-app.yaml`)
follows the *app-of-apps* pattern: it points at `argocd/apps/`, which contains
child Applications for every platform concern:

- `platform-kyverno` → installs Kyverno (Helm)
- `platform-observability` → installs OTel Collector + Jaeger (Helm) + ingress
- `platform-policies` → applies the Kyverno ClusterPolicies in `policies/`
- `tenants` → an ApplicationSet that fans out over `tenants/*` and `apps/*`

Because everything is a child of the root app, `bootstrap.sh` only has to
install Argo CD and apply one manifest. Argo does the rest and keeps it in sync.

### 2.2 Guardrails — Kyverno

Kyverno runs as a validating/mutating admission webhook. Every pod creation in
the cluster is checked against the `policies/`:

| Policy | Effect |
|---|---|
| `require-resource-limits` | Pods must declare CPU/memory requests + limits |
| `disallow-privileged` | No privileged containers, no host namespaces |
| `require-run-as-nonroot` | Containers must run as non-root |
| `restrict-image-registries` | Images only from the approved Harbor registry |

These are **cluster-wide** but written to skip system namespaces (kube-system,
argocd, etc.) so the platform itself isn't blocked. This is how the POC proves
"a customer cannot run an unsafe workload."

### 2.3 Tenancy — namespace + native controls

A tenant is a namespace plus a bundle of native controls, all rendered from
`tenants/_template/` by `onboard-tenant.sh`:

| Control | File | Purpose |
|---|---|---|
| Namespace | `namespace.yaml` | The tenant boundary (labelled `caas.tenant=<name>`) |
| ResourceQuota | `resourcequota.yaml` | Caps total CPU/memory/pods/PVCs |
| LimitRange | `limitrange.yaml` | Default + max per-container limits |
| RBAC | `rbac.yaml` | A `tenant-admin` Role bound to the tenant's group — scoped to *their* namespace only |
| NetworkPolicy | `networkpolicy.yaml` | default-deny ingress + allow from ingress-nginx |
| Argo AppProject | `appproject.yaml` | Restricts what the tenant's Argo apps may deploy and to which namespace |

Defense in depth: even if one control is misconfigured, the others still
contain the tenant.

### 2.4 Self-service — the golden-path chart

`golden-path/app/` is a reusable Helm chart. A customer supplies a small
`values.yaml` (image, port, host) and gets a production-shaped deployment:

```
Deployment  ── resources + securityContext (passes Kyverno by construction)
            ── OTEL_EXPORTER_OTLP_ENDPOINT → platform collector
Service     ── ClusterIP
Ingress     ── host <name>.<BASE_DOMAIN>, ingressClassName nginx,
               cert-manager annotation → automatic TLS
ServiceMonitor ── Prometheus Operator scrapes /metrics → Grafana
NetworkPolicy  ── allow ingress-nginx → app
```

The chart makes the *easy* path the *compliant* path: defaults already satisfy
the guardrails, wire observability, and request TLS.

### 2.5 Observability — traces + metrics

- **Traces:** the platform OTel Collector (in `platform-observability`) receives
  OTLP from tenant apps and exports to **Jaeger**. Tenant apps point at it via
  the `OTEL_EXPORTER_OTLP_ENDPOINT` injected by the golden-path chart.
- **Metrics:** reuse the cluster's existing **kube-prometheus-stack**. The
  golden-path chart emits a `ServiceMonitor`, which the Prometheus Operator
  discovers automatically; dashboards appear in the existing Grafana.

No metrics stack is duplicated — only the trace backend is added.

---

## 3. The request path (customer traffic)

```
1. Browser → https://wordpress.<BASE_DOMAIN>
2. DNS (*.<BASE_DOMAIN>) → HAProxy public IP
3. HAProxy → NodePort 30443 on a cluster node
4. ingress-nginx matches Host: wordpress... → tenant Service
5. NetworkPolicy permits ingress-nginx → app pod
6. App serves the response; emits traces (→ collector → Jaeger)
   and exposes /metrics (→ Prometheus → Grafana)
7. TLS terminated by nginx using the cert-manager-issued cert
```

---

## 4. The onboarding path (new tenant)

```
1. ./scripts/onboard-tenant.sh acme
   → renders tenants/acme/ from tenants/_template/
2. git commit + push
3. Argo CD ApplicationSet detects tenants/acme/ → creates an Application
4. Argo applies: namespace, quota, limitrange, rbac, netpol, AppProject
5. Tenant is live and isolated; their AppProject now permits their app to sync
```

---

## 5. Why these choices

- **App-of-apps + ApplicationSet** so adding a tenant is a directory + a commit,
  not a manual Argo registration.
- **Kyverno over Gatekeeper** for lower-friction policy authoring (YAML, no Rego)
  — important when the audience is a platform team, not policy experts.
- **Reusing kube-prometheus-stack** avoids running two Prometheis and keeps the
  POC honest about what's actually new (the trace backend + the platform glue).
- **AppProject per tenant** so GitOps self-service is itself tenant-scoped: a
  tenant's Argo apps can only target their namespace and approved sources.
