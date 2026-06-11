# Production-grade meshed app (Bookinfo on Istio)

A multi-service application running on the CaaS platform as a tenant, using
production Kubernetes + service-mesh patterns: sidecars, mTLS, distributed
tracing, canary, autoscaling, and disruption budgets — all open source.

---

## What it demonstrates

| Pattern | How |
|---|---|
| **Multi-service app** | Bookinfo: `productpage` → `details`, `reviews` → `ratings` (reviews has v1/v2/v3) |
| **Service mesh + sidecar** | Istio injects an `istio-proxy` sidecar into every pod (via istio-cni, so pods stay unprivileged) |
| **mTLS (zero-trust)** | `PeerAuthentication: STRICT` — all east-west traffic is mutually authenticated and encrypted |
| **Distributed tracing** | Sidecars emit spans (no app code changes) → OTel Collector → Jaeger; one trace spans all services |
| **Canary / traffic split** | `VirtualService` routes 80% reviews→v1, 20%→v2 |
| **Resilience** | Retries + timeout on reviews; outlier detection (circuit breaking); fault injection on ratings |
| **Autoscaling** | `HorizontalPodAutoscaler` on productpage (needs metrics-server) |
| **Availability** | `PodDisruptionBudget` + 2 frontend replicas |
| **Security guardrails** | Hardened to run non-root with limits → passes the platform's Kyverno policies |

---

## Architecture

```
   https://bookinfo.<domain>/productpage
        │  nginx ingress (TLS via cert-manager)
        ▼
   ┌─────────────────── tenant-bookinfo (istio-injection=enabled) ───────────────────┐
   │                                                                                  │
   │   productpage ─┬─mTLS─▶ details                                                  │
   │   (2 replicas) │                                                                 │
   │    +HPA,PDB    └─mTLS─▶ reviews ──VirtualService 80/20──▶ reviews-v1 (no stars)  │
   │                          │                              └▶ reviews-v2 (★ ratings)│
   │                          └─mTLS─▶ ratings  ◀── fault injection (2s delay 30%)    │
   │                                                                                  │
   │   every pod = app container + istio-proxy sidecar (unprivileged, istio-cni)      │
   └──────────────────────────────┬───────────────────────────────────────────────────┘
                                   │ sidecars emit OTLP spans
                                   ▼
                       otel-collector → Jaeger   (distributed traces)
```

North-south traffic enters through nginx (TLS at the edge); east-west traffic is
mTLS inside the mesh. productpage's port 9080 is `PERMISSIVE` so nginx (outside
the mesh) can reach it while every service-to-service hop stays STRICT.

---

## Demo runbook

Replace `<domain>` with `apps.k8-cmb1.gcloud.ca`.

### 1. The app
```
https://bookinfo.<domain>/productpage
```
Reload a few times — the **Book Reviews** panel flips between "no stars" (v1) and
"black stars" (v2): that's the canary split live in the browser.

### 2. Distributed tracing (the mesh's killer feature)
```
https://jaeger.<domain>     # Service dropdown: productpage.tenant-bookinfo
```
Open a trace — one request fans out across productpage → reviews → ratings,
each hop a span. **No application code was instrumented**; the sidecars did it.

### 3. mTLS (zero-trust)
```bash
kubectl -n tenant-bookinfo get peerauthentication        # default = STRICT
# Every east-west call is mTLS. Verify the running app still works (it does),
# proving services authenticate to each other.
```

### 4. Canary / traffic management
```bash
kubectl -n tenant-bookinfo get virtualservice reviews -o yaml   # 80/20 v1/v2
# Shift the split by editing the weights and committing — GitOps redeploys it.
```

### 5. Resilience
```bash
kubectl -n tenant-bookinfo get destinationrule        # outlier detection
kubectl -n tenant-bookinfo get virtualservice ratings -o yaml  # fault injection
# reviews has retries(3)+timeout(10s); ratings injects a 2s delay on 30% of calls.
```

### 6. Autoscaling
```bash
kubectl -n tenant-bookinfo get hpa productpage         # cpu %/70%, 2..5 replicas
# Drive load and watch REPLICAS climb:
kubectl -n tenant-bookinfo run load --image=docker.io/bitnamilegacy/kubectl:1.28.5 \
  --restart=Never -it --rm -- /bin/sh -c \
  'for i in $(seq 1 100000); do wget -q -O- http://productpage:9080/productpage >/dev/null; done'
```

### 7. It still passes the platform guardrails
```bash
kubectl -n tenant-bookinfo get policyreport            # Kyverno: PASS on non-root/limits
kubectl -n tenant-bookinfo get pods -o jsonpath='{.items[0].spec.initContainers[*].name}'
# -> istio-validation (NOT a privileged istio-init): istio-cni keeps pods unprivileged
```

---

## Why these choices

- **istio-cni** (not the default init container) so meshed pods need no elevated
  privileges and survive `restricted`/`baseline` PSA + the Kyverno guardrails.
- **Right-sized sidecar resources** (250m CPU limit, not Istio's 2000m default)
  so meshed multi-service apps fit a tenant ResourceQuota.
- **nginx at the edge + mesh inside** matches this cluster (HAProxy→nginx already
  wired); production could instead front with the Istio ingress gateway.
- **Bookinfo** because it's purpose-built to show mesh tracing + canary; its
  upstream images aren't restricted-hardened, so we add a non-root securityContext
  and run the tenant at `baseline` PSA (a real app would ship hardened images).
