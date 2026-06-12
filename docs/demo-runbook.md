# Demo runbook

A click-by-click walkthrough to show stakeholders the CaaS golden path. Assumes
`bootstrap.sh` has run and Argo CD is healthy. Replace `<BASE_DOMAIN>` with your
domain (e.g. `apps.k8-cmb1.gcloud.ca`).

---

## 0. Show the platform is GitOps-managed

```bash
kubectl -n argocd get applications
```

Point out: every platform component and tenant is an Argo Application synced
from the repo. Nothing here was kubectl-applied by hand.

Open the Argo CD UI (port-forward or its ingress) and show the app-of-apps tree.

---

## 1. Onboard a customer (platform team action)

```bash
./scripts/onboard-tenant.sh acme
git add tenants/acme && git commit -m "onboard tenant acme" && git push
```

Within ~1 minute Argo CD creates the tenant. Show the isolation that appeared:

```bash
kubectl get ns tenant-acme --show-labels
kubectl -n tenant-acme get resourcequota,limitrange,networkpolicy,rolebinding
kubectl get appproject -n argocd acme
```

**Talking point:** one PR produced a fully isolated tenant — quota, limits,
RBAC, network default-deny, and a scoped GitOps project.

---

## 2. Customer deploys their app (customer action, via Git)

The POC's application is a full-stack **WordPress + MySQL** stack in
`apps/wordpress/`, deployed by one Argo Application. Committing it is the whole
deployment — see [`fullstack-app.md`](fullstack-app.md) for the full feature
walkthrough.

```bash
kubectl -n argocd get application wordpress -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n tenant-wordpress get deploy,statefulset,pvc,svc,ingress,hpa,cronjob
```

Open it in a browser:

```
https://wordpress.<BASE_DOMAIN>
```

**Talking point:** the customer never ran `kubectl`. They committed manifests to
Git; the platform gave them a running, TLS-terminated, mesh-secured, autoscaling,
backed-up full-stack app — and auto-wired the TLS, mTLS, tracing, and metrics.

---

## 3. Show built-in observability

**Metrics (Grafana):**

```
https://grafana.<BASE_DOMAIN>   (or via the monitoring stack's ingress)
```

Show the app's metrics — they arrived automatically via the `ServiceMonitor`
the golden-path chart emitted.

**Traces (Jaeger):**

```
https://jaeger.<BASE_DOMAIN>
```

Generate some traffic / run the trace job, then find the service in Jaeger:

```bash
kubectl -n tenant-acme apply -f apps/acme-web/trace-demo-job.yaml   # telemetrygen
```

**Talking point:** observability is a platform feature, not something each team
re-implements.

---

## 4. Prove the guardrails (the "safe platform" moment)

Try to deploy a privileged pod into the tenant namespace:

```bash
kubectl -n tenant-acme apply -f - <<'EOF'
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

Expected: **Kyverno rejects it** at admission with a clear message
(privileged + non-Harbor registry + missing limits + runs as root).

**Talking point:** the platform enforced policy at the door — the customer
*cannot* run an unsafe or non-compliant workload, no manual review needed.

---

## 5. Prove tenant isolation

Verify the tenant-admin role is correctly scoped. NOTE: if your kubeconfig goes
through the Rancher proxy (server URL `.../k8s/clusters/...`), `kubectl --as`
impersonation is NOT honored — it evaluates as the admin account and returns
"yes" to everything. Test with a real ServiceAccount token instead:

```bash
kubectl -n tenant-acme create serviceaccount iso-test
kubectl -n tenant-acme create rolebinding iso-test --role=tenant-admin \
  --serviceaccount=tenant-acme:iso-test
TOK=$(kubectl -n tenant-acme create token iso-test --duration=10m)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
K="kubectl --server=$SERVER --token=$TOK --insecure-skip-tls-verify"

$K auth can-i create deployments -n tenant-acme   # yes  (own workloads)
$K auth can-i get pods -n kube-system             # no   (no cross-namespace)
$K auth can-i get nodes                           # no   (no cluster escalation)
$K auth can-i delete resourcequota -n tenant-acme # no   (can't raise own limits)
$K auth can-i create networkpolicies -n tenant-acme # no (can't open own network)

kubectl -n tenant-acme delete sa iso-test; kubectl -n tenant-acme delete rolebinding iso-test
```

Network isolation (default-deny means cross-tenant pod traffic is dropped):

```bash
kubectl -n tenant-other run probe --image=docker.io/library/busybox:1.36 --restart=Never -it --rm -- \
  wget -T3 -qO- http://acme-web.tenant-acme.svc.cluster.local || echo "blocked as expected"
```

**Talking point:** tenants are isolated by RBAC *and* by network policy —
defense in depth.

---

## 6. Tear down a tenant

```bash
git rm -r tenants/other apps/other-* 2>/dev/null; git commit -m "offboard other"; git push
# Argo prunes the namespace and all its resources.
```

---

## One-paragraph summary for the deck

> On a Rancher Kubernetes cluster using only open-source components — Argo CD,
> Kyverno, ingress-nginx, cert-manager, OpenTelemetry, Jaeger, Prometheus,
> Grafana, Longhorn, Harbor — we onboard a customer as an isolated tenant with a
> single pull request, and that customer self-serves a container through Git
> that comes up at an HTTPS URL with automatic TLS, built-in metrics and traces,
> enforced security guardrails, and hard isolation from every other tenant. The
> whole platform is reproducible from one repository in minutes.
