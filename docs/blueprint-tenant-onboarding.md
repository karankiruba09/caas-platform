# Design Blueprint — Tenant Onboarding (Platform Team)

**Audience:** Platform / SRE team (the "landlord")
**Status:** POC reference design
**Scope:** How a tenant is designed, secured, and provisioned on the ThinkOn
open-source Kubernetes platform — the *design* and the *security model*, not only
the steps.

---

## 1. Purpose & objectives

Provide **isolated, self-service, policy-governed** slices of a shared Kubernetes
cluster to internal/external customers ("tenants"), so that:

- a tenant is provisioned **in one step**, with security **on by default**;
- a tenant can do everything they need **inside their boundary** and **nothing**
  outside it;
- every control is **declarative and auditable** (GitOps), reproducible, and
  revocable;
- the platform team's effort per tenant trends to **zero** (templated, automated).

### Non-goals (POC)

- Hard multi-tenancy / per-tenant kernel isolation (no separate clusters, vClusters
  or Kata containers — this is **soft multi-tenancy** on a shared control plane).
- Production secrets management, chargeback/showback, and quota auto-scaling
  (called out in §10 as the hardening roadmap).

---

## 2. Design principles

| Principle | What it means here |
|---|---|
| **Isolation by default** | A new namespace denies all ingress and runs `restricted` Pod Security before any workload exists. |
| **Least privilege** | Tenants get a Role scoped to *their* namespace; never cluster scope, never their own guardrails. |
| **Defense in depth** | No single control is the only thing protecting a boundary — RBAC *and* NetworkPolicy *and* quota *and* Pod Security *and* admission policy. |
| **Policy as code** | Guardrails are Kyverno `ClusterPolicy` objects in Git, enforced at admission — not tribal knowledge. |
| **GitOps is the source of truth** | The desired state of every tenant lives in `tenants/<name>/`; Argo CD reconciles the cluster to it. |
| **Self-service** | Tenants deploy through their own scoped GitOps project and/or a namespace-scoped kubeconfig — no platform ticket per change. |
| **Reproducible & revocable** | Onboarding is templated and idempotent; offboarding prunes everything and revokes credentials. |

---

## 3. Tenancy model

**One tenant = one namespace** (`tenant-<name>`), on a shared cluster control
plane (soft multi-tenancy). This is the right granularity for the POC: cheap,
fast, and isolated enough when layered controls are applied.

```
        Shared cluster (one control plane, shared nodes)
   ┌──────────────────────────────────────────────────────────┐
   │  tenant-a            tenant-b            tenant-c          │
   │  ┌──────────┐        ┌──────────┐        ┌──────────┐      │
   │  │ ns +PSA  │        │ ns +PSA  │        │ ns +PSA  │      │
   │  │ quota    │   ✗◀──▶ │ quota    │  ✗◀──▶ │ quota    │      │  ✗ = denied by
   │  │ rbac     │ (netpol)│ rbac     │(netpol)│ rbac     │      │      NetworkPolicy
   │  │ netpol   │        │ netpol   │        │ netpol   │      │      + RBAC
   │  └──────────┘        └──────────┘        └──────────┘      │
   └──────────────────────────────────────────────────────────┘
```

**Isolation boundaries and the control that enforces each:**

| Boundary | Risk if absent | Enforcing control |
|---|---|---|
| Compute | one tenant starves others | **ResourceQuota** + **LimitRange** |
| Network | lateral movement between tenants | **default-deny NetworkPolicy** |
| API / RBAC | read/modify other tenants' objects | **namespace-scoped Role** + scoped SA |
| Workload | privileged/root container escape | **Pod Security `restricted`** + Kyverno |
| Supply chain | untrusted images | Kyverno **registry policy** |
| Delivery | deploy outside own namespace | Argo CD **AppProject** |

---

## 4. Logical design — components & responsibilities

```
   Platform team
        │ onboard-tenant.sh <name>
        ▼
   ┌────────────────────── per tenant ──────────────────────┐
   │ Namespace (caas.tenant=<name>, PSA=restricted)          │  ← boundary + workload policy
   │ ResourceQuota + LimitRange                              │  ← compute governance
   │ Role(tenant-admin) + ServiceAccount + RoleBinding       │  ← identity & authz (scoped)
   │ NetworkPolicy(default-deny + allow nginx/monitoring)    │  ← network isolation
   │ AppProject(<name>)                                       │  ← GitOps blast-radius
   └────────────────────────────────────────────────────────┘
        │ (cluster-wide, applies via caas.tenant label)
        ▼
   Kyverno ClusterPolicies: limits · runAsNonRoot · no-privileged · registry
        │
        ▼
   Output: namespace-scoped kubeconfig (out/tenant-<name>.kubeconfig)
```

Each object has one job; together they are defense in depth. Cluster-wide pieces
(Kyverno, Argo CD, ingress, cert-manager, mesh) are shared platform services that
*apply to* the tenant but are not owned by it.

---

## 5. Security design

### 5.1 Threat model (what we defend against)

| # | Threat | Scenario | Primary mitigation |
|---|---|---|---|
| T1 | **Noisy neighbour** | tenant consumes all CPU/RAM | ResourceQuota + LimitRange |
| T2 | **Lateral movement** | compromised pod scans/attacks other tenants | default-deny NetworkPolicy |
| T3 | **Privilege escalation** | privileged/root container escapes to node | Pod Security `restricted` + Kyverno no-privileged/non-root |
| T4 | **Authz escape** | tenant reads/edits other namespaces or cluster objects | namespace-scoped Role; no cluster verbs; can't edit own quota/netpol |
| T5 | **Self-relaxation** | tenant raises its own quota or opens its own network | guardrail objects excluded from the tenant Role |
| T6 | **Supply chain** | running untrusted/back-doored images | Kyverno registry policy (approved Harbor) |
| T7 | **GitOps blast radius** | tenant's CD pipeline deploys cluster-wide | per-tenant AppProject (namespace + repo + kind allow-list) |
| T8 | **Credential leak** | tenant kubeconfig stolen | short-TTL SA token, rotatable, revocable; namespace-scoped only |

### 5.2 Defense-in-depth layers

```
   Request to mutate the cluster as a tenant
        │
        ▼  AuthN  — who are you?            (SA token / OIDC group)
        ▼  AuthZ  — RBAC: only tenant-admin Role in tenant-<name>
        ▼  Admission — Pod Security (restricted) rejects unsafe pods
        ▼  Admission — Kyverno: limits, non-root, no-privileged, registry
        ▼  Quota   — ResourceQuota/LimitRange cap consumption
        ▼  Runtime — NetworkPolicy default-deny isolates traffic
   Any single layer failing still leaves the others.
```

### 5.3 Policy catalog (the controls, and *why* each exists)

| Control | Object | Default | Rationale |
|---|---|---|---|
| Workload safety | `pod-security.kubernetes.io/enforce: restricted` | restricted | Block privileged, host namespaces, root, added caps at the namespace gate. |
| CPU/mem cap | ResourceQuota | 2 CPU / 4Gi req, 4 CPU / 8Gi lim, 20 pods | Bound blast radius of a runaway tenant (T1). |
| No edge LB | `services.loadbalancers=0`, `nodeports=0` | 0 | Force ingress-only exposure; prevent port sprawl / accidental exposure. |
| Per-container defaults | LimitRange | 100m/128Mi req, 500m/512Mi lim | Sane defaults; satisfies the limits policy even if the tenant forgets. |
| Authz | Role `tenant-admin` (namespaced) | workload kinds only | Full control of *workloads*; **no** quota/limitrange/netpol verbs (T5), **no** cluster verbs (T4). |
| Identity | ServiceAccount `tenant-admin` | per tenant | Stable identity behind the issued kubeconfig. |
| Network | NetworkPolicy default-deny + allow `ingress-nginx`, `monitoring`, same-ns | deny-all then allow | Stop cross-tenant traffic (T2) while permitting ingress + scraping. |
| Delivery | AppProject `<name>` | ns + repo + kind allow-list | Tenant's Argo apps can only target their namespace, approved repo, approved kinds (T7). |
| Limits enforcement | Kyverno `require-resource-limits` (Enforce) | on | Every container must declare requests+limits. |
| Non-root | Kyverno `require-run-as-nonroot` (Enforce) | on, with `caas.allow-root` opt-out | Containers run non-root unless the namespace is explicitly labelled (audited exception). |
| No privilege | Kyverno `disallow-privileged` (Enforce) | on | No privileged containers / host namespaces (T3). |
| Registry | Kyverno `restrict-image-registries` (Audit→Enforce) | Harbor only | Images from the approved registry (T6); Audit in POC, Enforce after mirroring. |

### 5.4 Identity & access design

- **Mechanism:** a per-tenant `tenant-admin` **ServiceAccount**, bound to the
  namespace-scoped `tenant-admin` Role. The platform mints a **bound, time-limited
  token** and packages it as a kubeconfig with the tenant namespace as default
  context.
- **Why a ServiceAccount:** portable, scriptable, revocable (delete the SA → token
  invalid), and — verified on this Rancher cluster — RBAC is correctly enforced
  for SA tokens even through the Rancher proxy (unlike `--as` impersonation).
- **Human identity (production):** the RoleBinding also targets the group
  `caas:tenant:<name>`; wire that group to **Rancher Project membership / OIDC** so
  people authenticate as themselves and the SA token is reserved for automation.
- **Lifecycle:** tokens are short-TTL and rotated by re-issuing; offboarding deletes
  the SA to revoke immediately.

---

## 6. Resource governance

Default quota is a single "standard" tier (§5.3). Design intent: offer **t-shirt
sizes** (small/standard/large) selectable at onboarding, each a different
ResourceQuota/LimitRange pair. Mesh-enabled tenants get a larger default because
every pod also runs a sidecar (~100m/128Mi). LoadBalancer and NodePort services
are quota-zeroed by design — exposure is **ingress-only**.

---

## 7. The "how" — onboarding workflow

```bash
./scripts/onboard-tenant.sh <name> [--mesh] [--allow-root] [--gitops-only]
```

| Step | Action | Result |
|---|---|---|
| 1 | Render `tenants/<name>/` from `tenants/_template/` (token substitution) | declarative tenant spec |
| 2 | Apply opt-in labels (`istio-injection`, `caas.allow-root`/baseline PSA) | per-tenant options |
| 3 | `kubectl apply` (namespace first, then the rest) | tenant provisioned immediately |
| 4 | Wait for the `tenant-admin` ServiceAccount | identity ready |
| 5 | Mint token → write `out/tenant-<name>.kubeconfig` (gitignored) | credential to hand over |
| 6 | Print isolation summary + the GitOps commit to run | hand-off |

**Two operating modes:**
- **Direct + GitOps (default):** apply now for an instant credential, then commit
  `tenants/<name>/` so Argo adopts and reconciles it as source of truth.
- **Pure GitOps (`--gitops-only`):** render only; commit; Argo creates the tenant;
  then `issue-tenant-kubeconfig.sh` mints the credential.

---

## 8. Lifecycle management

```
  Provision ─▶ Operate ─▶ Rotate ─▶ Offboard
     │            │          │          │
 onboard-     monitor    issue-      git rm tenants/<name>
 tenant.sh    quota,     tenant-     + delete SA (revoke)
              policy     kubeconfig  + Argo prunes namespace
              reports    .sh <ttl>
```

- **Operate:** Kyverno PolicyReports per namespace show compliance; quota usage is
  observable; the tenant self-serves via GitOps/kubeconfig.
- **Rotate:** re-issue the kubeconfig (new bound token); old token expires.
- **Offboard:** `git rm tenants/<name>` → Argo prunes the namespace and all
  resources; delete the SA to immediately revoke any outstanding token.

---

## 9. Roles & responsibilities

| Activity | Platform team | Tenant team |
|---|---|---|
| Define guardrails / policies | **Owns** | consumes |
| Onboard / offboard tenant | **Owns** | requests |
| Issue / rotate credentials | **Owns** | receives |
| Set quota tier | **Owns** | requests change |
| Deploy workloads in namespace | reviews policy | **Owns** |
| Respond to policy violations | advises | **Owns** remediation |

---

## 10. Production hardening roadmap

| Area | POC state | Production target |
|---|---|---|
| Secrets | demo Secrets in Git | Sealed Secrets / External Secrets / Vault |
| Identity | SA-token kubeconfig | Rancher Projects + OIDC (humans as themselves) |
| Registry policy | Audit | Enforce, with images mirrored to Harbor + signature verification (Cosign) |
| Egress | open | default-deny **egress** + explicit allow-lists |
| Isolation | soft (shared control plane) | optional vCluster / dedicated node pools for sensitive tenants |
| Quota | single tier | t-shirt sizes + chargeback/showback |
| Audit | cluster audit log | per-tenant audit views, policy-report alerting |
| DR | none | namespace backup/restore (Velero), tested runbooks |

---

## 11. Summary

A tenant is **a namespace plus a bundle of independent, declarative controls** —
compute, network, identity, workload, supply-chain, and delivery — provisioned in
one command and handed over as a scoped credential. Security is **on by default
and enforced at admission**, the desired state is **in Git**, and every step is
**reproducible and revocable**. See [`platform-onboarding.md`](platform-onboarding.md)
for the operator runbook.
