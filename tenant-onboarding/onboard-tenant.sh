#!/usr/bin/env bash
#
# onboard-tenant.sh <name> [flags] -- PLATFORM TEAM one-step tenant onboarding.
#
# In a single command it provisions a fully isolated, guard-railed tenant and
# issues a namespace-scoped kubeconfig to hand to the tenant. Everything the
# tenant gets is least-privilege and policy-enforced by construction:
#   • Namespace with Pod Security (restricted by default)
#   • ResourceQuota + LimitRange
#   • RBAC: tenant-admin Role + ServiceAccount (scoped to the namespace only)
#   • default-deny NetworkPolicy (+ ingress-nginx / monitoring allows)
#   • Argo CD AppProject (scoped GitOps self-service)
#   • Kyverno cluster policies apply automatically (via the caas.tenant label)
#
# Usage:
#   ./tenant-onboarding/onboard-tenant.sh x                     # restricted, non-root, no mesh
#   ./tenant-onboarding/onboard-tenant.sh x --mesh              # add Istio sidecar injection
#   ./tenant-onboarding/onboard-tenant.sh x --allow-root        # baseline PSA + root opt-out
#   ./tenant-onboarding/onboard-tenant.sh x --gitops-only       # render only; commit to apply
#
# Default behaviour applies the tenant immediately (so the kubeconfig can be
# issued) AND leaves the rendered manifests under tenant-onboarding/tenants/<name>/ for you to
# commit — Argo then adopts and reconciles them as the source of truth.
#
set -euo pipefail

usage() {
  echo "usage: onboard-tenant.sh <name> [--mesh] [--allow-root] [--gitops-only] [--no-kubeconfig]" >&2
}

TENANT=""; MESH=false; ALLOW_ROOT=false; GITOPS_ONLY=false; NO_KUBECONFIG=false
for arg in "$@"; do
  case "${arg}" in
    --mesh)          MESH=true ;;
    --allow-root)    ALLOW_ROOT=true ;;
    --gitops-only)   GITOPS_ONLY=true ;;
    --no-kubeconfig) NO_KUBECONFIG=true ;;
    -*)              echo "unknown flag: ${arg}" >&2; usage; exit 1 ;;
    *)               TENANT="${arg}" ;;
  esac
done

[[ -n "${TENANT}" ]] || { usage; exit 1; }
if ! [[ "${TENANT}" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "invalid tenant name '${TENANT}': use lowercase RFC-1123 (a-z, 0-9, -)." >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/tenant-onboarding/template"
DST="${ROOT}/tenant-onboarding/tenants/${TENANT}"
NS="tenant-${TENANT}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ -e "${DST}" ]] && { echo "tenant-onboarding/tenants/${TENANT} already exists — aborting." >&2; exit 1; }
[[ -d "${SRC}" ]] || { echo "tenant template directory not found: ${SRC}" >&2; exit 1; }
if ! ${GITOPS_ONLY}; then
  command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
fi

# --- 1. Render the tenant from the template ------------------------------------
log "Rendering tenant '${TENANT}' from the template"
mkdir -p "${DST}"
for f in "${SRC}"/*.yaml; do
  sed "s/__TENANT__/${TENANT}/g" "$f" > "${DST}/$(basename "$f")"
done

# --- 2. Apply opt-in namespace options -----------------------------------------
NSFILE="${DST}/namespace.yaml"
if ${ALLOW_ROOT}; then
  log "Option: --allow-root (baseline PSA + root opt-out)"
  sed -i 's/: restricted/: baseline/g' "${NSFILE}"
  sed -i '/caas.tenant:/a\    caas.allow-root: "true"' "${NSFILE}"
fi
if ${MESH}; then
  log "Option: --mesh (Istio sidecar injection)"
  sed -i '/caas.tenant:/a\    istio-injection: enabled' "${NSFILE}"
fi

echo "    files:"; ls -1 "${DST}" | sed 's/^/      /'

if ${GITOPS_ONLY}; then
  cat <<EOF

Rendered tenant-onboarding/tenants/${TENANT}/ (not applied). To provision via GitOps:
  git add tenant-onboarding/tenants/${TENANT} && git commit -m "onboard tenant ${TENANT}" && git push
Then issue a kubeconfig:
  ./tenant-onboarding/issue-tenant-kubeconfig.sh ${TENANT}
EOF
  exit 0
fi

# --- 3. Provision immediately --------------------------------------------------
log "Applying tenant resources to the cluster"
# Namespace first so the namespaced resources have somewhere to land.
kubectl apply -f "${DST}/namespace.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Active "namespace/${NS}" --timeout=30s >/dev/null 2>&1 || true
kubectl apply -f "${DST}"

log "Waiting for the tenant-admin ServiceAccount"
for _ in {1..30}; do
  kubectl -n "${NS}" get serviceaccount tenant-admin >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n "${NS}" get serviceaccount tenant-admin >/dev/null

# --- 4. Issue the namespace-scoped kubeconfig ----------------------------------
if ! ${NO_KUBECONFIG}; then
  log "Issuing namespace-scoped kubeconfig"
  "${ROOT}/tenant-onboarding/issue-tenant-kubeconfig.sh" "${TENANT}"
fi

# --- 5. Summary ----------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')Tenant '${TENANT}' onboarded.$(printf '\033[0m')

  Isolation in place:
$(kubectl -n "${NS}" get resourcequota,limitrange,networkpolicy,serviceaccount,rolebinding --no-headers 2>/dev/null | awk '{print "    "$1}')
    appproject/${TENANT} (argocd)

  Track it in GitOps (Argo adopts the already-applied resources):
    git add tenant-onboarding/tenants/${TENANT} && git commit -m "onboard tenant ${TENANT}" && git push

  The tenant's developer journey (deploying an app) is in demo/README.md.
EOF
