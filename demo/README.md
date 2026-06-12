# Demo

This folder is the tenant team's application onboarding demo. It bundles the
full-stack WordPress + MySQL application and the branded **portal** front-door,
both deployed by one Argo Application into one namespace (`tenant-wordpress`).

## What It Demonstrates

- tenant-owned GitOps delivery through Argo CD
- public Ingress with cert-manager TLS (WordPress app + portal)
- WordPress Deployment with HPA and PDB
- MySQL StatefulSet with Longhorn persistent storage
- Secrets, ConfigMaps, init containers, Job, and CronJob
- Istio sidecars, namespace mTLS, and sidecar-generated traces
- Prometheus scraping and Jaeger traces through platform-provided services
- Kyverno policy enforcement inherited from tenant onboarding
- a static portal (nginx-unprivileged) co-located in the demo namespace — no
  namespace of its own — meshed with a port-level PERMISSIVE ingress exception

## GitOps Entry Point

`application.yaml` is discovered by the platform app-of-apps and deploys this
folder into `tenant-wordpress` under the `wordpress` AppProject. The portal pages
are delivered via the `portal-html` ConfigMap generated from the `*.html` / logo.

```bash
kubectl -n argocd get application wordpress
kubectl -n tenant-wordpress get pods,pvc,ingress
```

## Live Demo Checks

```bash
kubectl -n tenant-wordpress get deploy,statefulset,hpa,pdb
kubectl -n tenant-wordpress get job,cronjob
kubectl -n tenant-wordpress get peerauthentication
```

Open the app and the portal:

```text
https://wordpress.apps.k8-cmb1.gcloud.ca
https://portal.apps.k8-cmb1.gcloud.ca
```

Open traces:

```text
https://jaeger.apps.k8-cmb1.gcloud.ca
```

The application does not import an OpenTelemetry SDK. Istio emits sidecar traces
and sends them to the platform OpenTelemetry Collector.
