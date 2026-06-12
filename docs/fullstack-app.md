# The application: WordPress + MySQL (full-stack, on the mesh)

The POC's single application — a best-in-class, real full-stack app that
exercises essentially the entire Kubernetes surface, deployed onto the platform
by one GitOps commit. The point isn't WordPress; it's **how little it takes to
run a real, stateful, production-shaped app here.**

Live: **https://wordpress.apps.k8-cmb1.gcloud.ca**

---

## Architecture

```
        https://wordpress.apps.k8-cmb1.gcloud.ca
             │  nginx ingress (TLS via cert-manager)
             ▼
   ┌──────────────── tenant-wordpress (istio-injection=enabled) ────────────────┐
   │                                                                             │
   │   WordPress (web/PHP-Apache)                MySQL (database)                │
   │   Deployment, 2 replicas        ──mTLS──▶   StatefulSet, 1 replica          │
   │   HPA (2→4 on CPU), PDB                     headless Service                 │
   │   init: wait-for-mysql                      ConfigMap (my.cnf)              │
   │   ConfigMap (php uploads.ini)                                               │
   │        │                                         │                          │
   │        ▼ RWX volume (shared)                     ▼ RWO volume               │
   │   Longhorn PVC (wordpress-content)          Longhorn PVC (data-mysql-0)     │
   │                                                                             │
   │   Secret (DB + admin creds)  ── consumed by web, db, jobs                   │
   │   Job: wp-cli install + seed   CronJob: mysqldump backup → Longhorn PVC     │
   │                                                                             │
   │   every pod has an istio-proxy sidecar (mTLS, traces) via istio-cni         │
   └───────────────────────────────┬─────────────────────────────────────────────┘
                                    │ sidecar OTLP spans
                                    ▼
                        otel-collector → Jaeger ;  Prometheus/Grafana
```

---

## Kubernetes features exercised

| Feature | Where it shows up |
|---|---|
| **Deployment** + rolling update | WordPress web tier (2 replicas) |
| **StatefulSet** + stable identity | MySQL |
| **PersistentVolumeClaim / StorageClass** | 3 Longhorn PVCs |
| **ReadWriteOnce** + **ReadWriteMany** | MySQL data (RWO) + shared WordPress content (RWX) |
| **Secret** | DB + admin credentials, consumed by web/db/jobs |
| **ConfigMap** | MySQL `my.cnf`, PHP `uploads.ini` |
| **init container** | wait-for-mysql before WordPress starts |
| **Job** | `wp-cli` install + first post |
| **CronJob** | scheduled `mysqldump` backup to a PVC |
| **HorizontalPodAutoscaler** | WordPress 2→4 replicas on CPU (metrics-server) |
| **PodDisruptionBudget** | keep ≥1 WordPress pod during disruptions |
| **headless Service** | MySQL stable DNS |
| **Ingress + TLS** | nginx + cert-manager |
| **Service mesh** (sidecar, **mTLS**, tracing) | Istio across web↔db |
| **NetworkPolicy / RBAC / PodSecurity** | tenant guardrails |
| **Policy as code** | Kyverno (limits enforced; `caas.allow-root` opt-out for Apache) |
| **Observability** | OTLP traces → Jaeger; metrics → Prometheus |

That's the full picture: stateless + **stateful**, storage, secrets, batch, scaling, mesh, security, observability.

---

## The "easy deployment" story

The entire stack above is **one Argo Application** pointing at one kustomize
bundle (`apps/wordpress/`). A single commit brings up web + database + cache
jobs + storage + mesh, and the platform automatically layers on:

- TLS certificate (cert-manager)
- mesh mTLS + distributed tracing (Istio) — **no app changes**
- metrics scraping (Prometheus)
- policy guardrails (Kyverno)
- tenant isolation (namespace, quota, RBAC, NetworkPolicy)

The application author wrote Kubernetes manifests and a values bundle; they did
**not** wire TLS, tracing, mTLS, scraping, or policy — the platform did.

---

## Demo runbook

### 1. The app
Open **https://wordpress.apps.k8-cmb1.gcloud.ca** — a fully installed WordPress
site (title "CaaS Demo — Deployed via GitOps", with a seeded first post). The
admin is at `/wp-admin` (credentials in the `wordpress-db` Secret — demo only).

### 2. It's genuinely stateful (storage)
```bash
kubectl -n tenant-wordpress get pvc          # 3 Longhorn volumes, RWO + RWX
kubectl -n tenant-wordpress get statefulset   # mysql with stable identity
```
Delete the WordPress pods — content survives (it's on the RWX volume); delete
`mysql-0` — the data survives (StatefulSet re-attaches its PVC).

### 3. Scaling (HPA)
```bash
kubectl -n tenant-wordpress get hpa wordpress     # cpu %/70%, 2..4
# drive load and watch REPLICAS climb (RWX lets replicas share content):
kubectl -n tenant-wordpress run load --image=docker.io/bitnamilegacy/kubectl:1.28.5 \
  --restart=Never -it --rm -- sh -c \
  'while true; do wget -q -O- http://wordpress/ >/dev/null; done'
```

### 4. Batch (Job + CronJob)
```bash
kubectl -n tenant-wordpress get job,cronjob       # wp-install (done), mysql-backup
kubectl -n tenant-wordpress create job --from=cronjob/mysql-backup backup-now
kubectl -n tenant-wordpress logs job/backup-now    # writes wordpress-<ts>.sql.gz to the PVC
```

### 5. Mesh: mTLS + tracing
```bash
kubectl -n tenant-wordpress get peerauthentication   # STRICT
# Traces (no app instrumentation): open Jaeger, service "wordpress.tenant-wordpress"
```
`https://jaeger.apps.k8-cmb1.gcloud.ca`

### 6. Guardrails still apply
```bash
kubectl -n tenant-wordpress get policyreport         # Kyverno: limits enforced
# WordPress runs as root via the explicit caas.allow-root namespace opt-out;
# every other tenant still requires non-root.
```

### 7. The deployment itself
```bash
kubectl -n argocd get application wordpress          # Synced/Healthy
# The whole stack came from: apps/wordpress/ (one Application, one commit).
```

---

## Honest notes

- **Secrets** are committed as throwaway demo values for a self-contained POC.
  Production must use Sealed Secrets / External Secrets / Vault.
- **WordPress runs as root** (Apache) via an explicit, labelled namespace
  opt-out; the platform's default is non-root everywhere.
- **MySQL is single-replica** with a StatefulSet PVC — fine for a POC; a real
  deployment would use a replicated operator (e.g. the MySQL/Percona operator).
