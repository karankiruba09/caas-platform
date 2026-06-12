#!/usr/bin/env bash
#
# bootstrap.sh -- install Argo CD and hand it this repo (app-of-apps). After
# this, Argo CD reconciles everything else: Kyverno, policies, observability,
# tenants, and tenant applications. The whole platform comes up in a few minutes.
#
# Usage:
#   ./platform-onboarding/bootstrap.sh
#
# To retarget the committed GitOps URLs/domains first:
#   REPO_URL=https://git.example.com/team/platform-engineering.git \
#   BASE_DOMAIN=apps.example.com \
#   CLUSTER_ISSUER=letsencrypt-prod \
#   ./platform-onboarding/set-cluster.sh
#
# IMPORTANT: this repo must already be pushed to its Git remote, because Argo CD
# pulls manifests from Git (not your local working copy). Build first, push,
# then bootstrap.
#
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v git >/dev/null || { echo "git not found"; exit 1; }

REPO_URL="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
ROOT_REPO="$(awk '/repoURL:/ { print $2; exit }' "${SCRIPT_DIR}/argocd/root-app.yaml")"

log "Target context : $(kubectl config current-context)"
log "Argo CD        : ${ARGOCD_VERSION} in namespace ${ARGOCD_NAMESPACE}"
log "Repo (local)   : ${REPO_URL:-<no origin remote>}"
log "Repo (root-app): ${ROOT_REPO}"

if [[ -n "${REPO_URL}" && "${REPO_URL%.git}" != "${ROOT_REPO%.git}" ]]; then
  warn "Your git origin differs from the repoURL committed in argocd/."
  warn "Run platform-onboarding/set-cluster.sh to retarget, then commit & push before bootstrapping."
fi

# --- Preflight: shared cluster infra this POC depends on -------------------
log "Preflight checks"
kubectl get ingressclass nginx >/dev/null 2>&1 || warn "ingressclass 'nginx' not found"
kubectl get clusterissuer letsencrypt-cloudflare >/dev/null 2>&1 \
  || warn "clusterissuer 'letsencrypt-cloudflare' not found -- TLS will stay Pending"
kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 \
  || warn "Prometheus Operator CRDs not found -- ServiceMonitors won't be scraped"

# --- 1. Install Argo CD ----------------------------------------------------
log "Installing Argo CD"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${ARGOCD_NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Annotation-based resource tracking: the default label tracking overwrites
# app.kubernetes.io/instance on every resource, which breaks Helm charts that
# rely on that label for ClusterRole aggregation (e.g. Kyverno). Annotation
# tracking avoids that whole class of bug.
log "Configuring annotation-based resource tracking"
kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'

# Server-side diff: newer Kubernetes (>=1.33) adds Deployment status fields like
# terminatingReplicas that older Argo client-side structured-merge diff can't
# parse (breaks ServerSideApply apps such as Kyverno). Server-side diff uses the
# API server's own schema, which knows the field.
log "Enabling server-side diff"
kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"controller.diff.server.side":"true"}}'

# Run argocd-server in insecure mode so the shared nginx ingress can terminate
# TLS and proxy plain HTTP (see platform-onboarding/services/argocd-ingress/). The UI is then at
# https://argocd.<BASE_DOMAIN>.
log "Enabling argocd-server insecure mode (TLS terminated at ingress)"
kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'

log "Waiting for Argo CD to become ready"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" wait --for=condition=established \
  crd/applications.argoproj.io crd/appprojects.argoproj.io --timeout=120s

# --- 2. Hand Argo the repo (app-of-apps) ----------------------------------
log "Applying the root app-of-apps"
kubectl apply -f "${SCRIPT_DIR}/argocd/root-app.yaml"

# --- 3. Report -------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')Argo CD installed and reconciling this repo.$(printf '\033[0m')

  Watch it converge:
    kubectl -n ${ARGOCD_NAMESPACE} get applications -w

  Argo CD UI (port-forward):
    kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server 8080:443
    open https://localhost:8080

  Initial admin password, if it has not been rotated:
    kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

  Next:
    ./tenant-onboarding/onboard-tenant.sh demo      # onboard a new tenant
    git add tenant-onboarding/tenants/demo && git commit -m "onboard demo" && git push
    # The full-stack demo (demo/) is already in the repo and syncs too.

  Demo guide: demo/README.md
EOF
