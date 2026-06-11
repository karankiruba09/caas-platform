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

The customer's app lives in `apps/acme-web/` and is deployed through the
golden-path chart. It is already wired into Argo, so committing it is the whole
deployment:

```bash
kubectl -n argocd get application acme-web -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n tenant-acme get deploy,svc,ingress,servicemonitor
```

Open it in a browser:

```
https://acme-web.<BASE_DOMAIN>
```

**Talking point:** the customer never ran `kubectl`. They committed to Git; the
platform gave them a running app at an HTTPS URL with a valid certificate.

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

Onboard a second tenant and show they can't reach across:

```bash
./scripts/onboard-tenant.sh other
git add tenants/other && git commit -m "onboard tenant other" && git push
# wait for sync, then:
kubectl auth can-i get pods -n tenant-acme \
  --as=system:serviceaccount:tenant-other:default        # -> no
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
