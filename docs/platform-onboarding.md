# Platform-team guide: onboarding a tenant

This is the **platform team's** side of the CaaS/KaaS — the "landlord" workflow.
It provisions an isolated, fully guard-railed tenant and hands back a
namespace-scoped credential, in one step. (The tenant's own side — deploying an
application — is [`fullstack-app.md`](fullstack-app.md).)

---

## One command

```bash
./scripts/onboard-tenant.sh <name> [--mesh] [--allow-root] [--gitops-only]
```

Example — onboard a tenant called `x`:

```bash
./scripts/onboard-tenant.sh x
```

That single command:

1. **Renders** the tenant from `tenants/_template/` → `tenants/x/`
2. **Provisions** it on the cluster (namespace + all controls below)
3. **Issues** a namespace-scoped kubeconfig → `out/tenant-x.kubeconfig`
4. Prints what to commit so Argo CD tracks it as the GitOps source of truth

---

## What the tenant gets (security by construction)

Every one of these is created automatically; none is optional:

| Control | Purpose |
|---|---|
| **Namespace** `tenant-x` | the boundary; labelled `caas.tenant=x` |
| **Pod Security** = `restricted` | no privileged/root/hostNamespace pods (baseline only with `--allow-root`) |
| **ResourceQuota** | caps total CPU/memory/pods/PVCs; **0 LoadBalancers/NodePorts** |
| **LimitRange** | default + max per-container limits |
| **RBAC** `tenant-admin` Role | full control over workloads **in this namespace only** — *not* over its own quota/limits/network |
| **ServiceAccount** `tenant-admin` | the identity behind the kubeconfig |
| **NetworkPolicy** default-deny | + allow ingress-nginx and Prometheus only |
| **Argo CD AppProject** `x` | scopes the tenant's GitOps apps to their namespace + approved repo |
| **Kyverno policies** | apply automatically via the `caas.tenant` label (limits, non-root, no-privileged, registry) |

Defense in depth: RBAC, NetworkPolicy, ResourceQuota, Pod Security, Kyverno, and
the AppProject all constrain the tenant independently.

### Flags

| Flag | Effect |
|---|---|
| `--mesh` | label the namespace `istio-injection=enabled` (sidecar, mTLS, tracing) |
| `--allow-root` | baseline Pod Security + `caas.allow-root` label (opt out of the non-root Kyverno rule — e.g. for WordPress/Apache) |
| `--gitops-only` | render only; you commit and let Argo apply (no direct apply, no kubeconfig) |

---

## The access mechanism: a namespace-scoped kubeconfig

The tenant identity is the `tenant-admin` **ServiceAccount** in their namespace,
bound to the `tenant-admin` Role. `onboard-tenant.sh` mints a token from it and
writes a ready-to-use kubeconfig:

```bash
out/tenant-x.kubeconfig          # contains a bearer token — gitignored, never commit
```

Hand that file to the tenant. They use it as-is:

```bash
KUBECONFIG=out/tenant-x.kubeconfig kubectl get pods      # works (their namespace)
KUBECONFIG=out/tenant-x.kubeconfig kubectl get nodes     # Forbidden
KUBECONFIG=out/tenant-x.kubeconfig kubectl get pods -n kube-system   # Forbidden
```

It grants exactly the `tenant-admin` Role in `tenant-x` and nothing else — no
cross-namespace access, no cluster scope, and it cannot raise its own quota or
open its own network.

### Rotating / re-issuing

```bash
./scripts/issue-tenant-kubeconfig.sh x 168h      # new 7-day token
```

Tokens are time-bound (the API server caps the max). Re-run to rotate.

### Other access mechanisms

The kubeconfig is the portable default. In a Rancher-managed cluster you can
additionally (or instead):

- **Rancher Project / namespace membership** — bind the tenant's IdP group to a
  Rancher Project that owns the namespace (the RoleBinding already targets the
  group `caas:tenant:x`; wire that group in Rancher/OIDC).
- **OIDC** — same RoleBinding group, backed by your identity provider, so tenants
  authenticate as themselves rather than via a shared ServiceAccount token.

---

## Track it in GitOps

Direct-apply gets the tenant (and credential) live immediately. To make Git the
source of truth, commit the rendered manifests — Argo CD adopts the already
applied resources and reconciles them from then on:

```bash
git add tenants/x && git commit -m "onboard tenant x" && git push
```

(For a pure-GitOps flow with no direct apply, use `--gitops-only`, commit, let
Argo create the tenant, then run `issue-tenant-kubeconfig.sh`.)

---

## Offboarding

```bash
git rm -r tenants/x && git commit -m "offboard tenant x" && git push
# Argo prunes the namespace and everything in it. Also revoke any issued tokens:
kubectl -n tenant-x delete serviceaccount tenant-admin   # invalidates the kubeconfig
```

---

## The two journeys (different teams)

| | Audience | Entry point |
|---|---|---|
| **Provision a tenant** | platform team | this doc · `scripts/onboard-tenant.sh` |
| **Deploy an application** | tenant / app team | [`fullstack-app.md`](fullstack-app.md) · their AppProject + kubeconfig |

They share this repo for the POC but are operated independently.
