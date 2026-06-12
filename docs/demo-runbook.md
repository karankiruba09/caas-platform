# Demo runbook

A click-by-click walkthrough for stakeholders. Assumes `bootstrap.sh` has run and
Argo CD is healthy. Replace `<BASE_DOMAIN>` with your domain (e.g.
`apps.k8-cmb1.gcloud.ca`).

The POC's application (`wordpress`) is already deployed; this runbook also onboards
a throwaway tenant (`demo`) to show the onboarding, guardrail, and isolation
mechanics on a clean namespace.

---

## 0. Show the platform is GitOps-managed

```bash
kubectl -n argocd get applications
```

Every platform component and tenant is an Argo Application synced from the repo —
nothing was kubectl-applied by hand. Open the Argo CD UI and show the app-of-apps
tree: `https://argocd.<BASE_DOMAIN>`.

---

## 1. The application — a full-stack app from one commit

The POC app is a full-stack **WordPress + MySQL** stack (`apps/wordpress/`),
deployed by one Argo Application. Full feature walkthrough:
[`fullstack-app.md`](fullstack-app.md).

```bash
kubectl -n argocd get application wordpress -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n tenant-wordpress get deploy,statefulset,pvc,svc,ingress,hpa,cronjob
```

Open it: `https://wordpress.<BASE_DOMAIN>`

**Talking point:** the author committed Kubernetes manifests; the platform gave
them a running, TLS-terminated, mesh-secured, autoscaling, backed-up full-stack
app — and auto-wired the TLS, mTLS, tracing, and metrics. They never wired any of
that.

---

## 2. Built-in observability (no app instrumentation)

Generate some traffic, then open Jaeger and pick service
`wordpress.tenant-wordpress`:

```bash
for i in $(seq 1 20); do curl -s -o /dev/null https://wordpress.<BASE_DOMAIN>/; done
```
`https://jaeger.<BASE_DOMAIN>`

**Talking point:** the distributed traces come from the Istio sidecars — the app
was not instrumented. Observability is a platform feature. (Mesh metrics also
flow to Prometheus/Grafana at `https://grafana.<BASE_DOMAIN>`.)

---

## 3. Onboard a new customer (platform team action) — one step

```bash
./scripts/onboard-tenant.sh demo
```

That single command provisions the whole tenant **and** issues a
namespace-scoped kubeconfig. Show the isolation that appeared:

```bash
kubectl get ns tenant-demo --show-labels
kubectl -n tenant-demo get resourcequota,limitrange,networkpolicy,serviceaccount,rolebinding
kubectl -n argocd get appproject demo
ls out/tenant-demo.kubeconfig          # the credential to hand to the tenant
```

**Talking point:** one command produced a fully isolated tenant — quota, limits,
RBAC, network default-deny, Pod Security, a scoped GitOps project, *and* a
ready-to-use namespace-scoped kubeconfig. (See
[`platform-onboarding.md`](platform-onboarding.md).) Commit `tenants/demo/` to
track it in GitOps.

---

## 4. Prove the guardrails (the "safe platform" moment)

Try to deploy a privileged, root, unlimited pod into the new tenant:

```bash
kubectl -n tenant-demo apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: rogue
spec:
  containers:
    - name: rogue
      image: docker.io/library/busybox:1.36
      securityContext:
        privileged: true
      command: ["sleep", "3600"]
EOF
```

Expected: **rejected at admission** — Pod Security (baseline/restricted) and
Kyverno both fire (privileged + runs-as-root + missing limits).

```bash
kubectl -n tenant-demo get policyreport     # Kyverno PASS/FAIL per workload
```

**Talking point:** the platform enforces policy at the door — a customer *cannot*
run an unsafe or non-compliant workload, no manual review. (WordPress runs as root
only because `tenant-wordpress` carries an explicit `caas.allow-root` label; every
other tenant, like `demo`, still requires non-root.)

---

## 5. Prove tenant isolation

**RBAC** — use the tenant's own issued kubeconfig (the one they'd receive) to
prove it is namespace-scoped. (This also sidesteps the Rancher proxy, which
ignores `kubectl --as` impersonation and evaluates as admin.)

```bash
K="kubectl --kubeconfig=out/tenant-demo.kubeconfig"

$K auth can-i create deployments              # yes  (their namespace)
$K get pods -n tenant-wordpress               # Forbidden (no cross-tenant)
$K get nodes                                  # Forbidden (no cluster escalation)
$K get namespaces                             # Forbidden (can't list cluster)
$K auth can-i delete resourcequota            # no   (can't raise own limits)
$K auth can-i create networkpolicies          # no   (can't open own network)
```

**Network** — default-deny drops cross-tenant pod traffic. From `demo`, try to
reach the WordPress service in `tenant-wordpress`:

```bash
kubectl -n tenant-demo run probe --image=docker.io/library/busybox:1.36 \
  --restart=Never -it --rm -- \
  wget -T3 -qO- http://wordpress.tenant-wordpress.svc.cluster.local || echo "blocked as expected"
```

**Talking point:** tenants are isolated by RBAC *and* by NetworkPolicy — defense
in depth.

---

## 6. Offboard the demo tenant

```bash
git rm -r tenants/demo && git commit -m "offboard tenant demo" && git push
# Argo prunes the namespace and all its resources.
```

---

## One-paragraph summary for the deck

> On a Rancher Kubernetes cluster using only open-source components — Argo CD,
> Kyverno, Istio, ingress-nginx, cert-manager, OpenTelemetry, Jaeger, Prometheus,
> Grafana, Longhorn, metrics-server, Harbor — we onboard a customer as an isolated
> tenant with a single pull request, and that customer self-serves a **full-stack
> application** (web + database + persistent storage + batch jobs) through Git. It
> comes up at an HTTPS URL with automatic TLS, mesh mTLS, built-in distributed
> tracing, autoscaling, backups, enforced security guardrails, and hard isolation
> from every other tenant — reproducible from one repository in minutes.
