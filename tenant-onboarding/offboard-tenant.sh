#!/usr/bin/env bash
#
# offboard-tenant.sh <name> [flags] -- PLATFORM TEAM one-step tenant offboarding.
#
# The exact inverse of onboard-tenant.sh: it tears down everything that
# onboarding created and revokes the tenant's credential, in one command.
# Onboarding is templated and idempotent; offboarding prunes everything and
# revokes the token — so a tenant leaves no residue behind:
#   • Argo CD Applications the tenant deployed under their AppProject
#   • Argo CD AppProject <name>
#   • Namespace tenant-<name> (cascades: ResourceQuota, LimitRange, RBAC,
#     ServiceAccount → outstanding kubeconfig tokens are revoked, NetworkPolicies,
#     and every workload/PVC the tenant ran)
#   • The rendered manifests under tenant-onboarding/tenants/<name>/ (so Argo stops reconciling them)
#   • App manifests under demo/ that target the tenant (so Argo cannot recreate
#     stale tenant Applications)
#   • The issued kubeconfig out/tenant-<name>.kubeconfig
#
# Usage:
#   ./tenant-onboarding/offboard-tenant.sh x                    # delete from cluster + remove dir/kubeconfig
#   ./tenant-onboarding/offboard-tenant.sh x --gitops-only      # remove Git manifests; commit to let Argo prune
#   ./tenant-onboarding/offboard-tenant.sh x --yes              # skip the destructive-action confirmation
#   ./tenant-onboarding/offboard-tenant.sh x --dry-run          # show what would happen, change nothing
#   ./tenant-onboarding/offboard-tenant.sh x --keep-kubeconfig  # leave out/tenant-x.kubeconfig in place
#
# Default behaviour deletes the tenant from the cluster immediately (so the
# credential is revoked now) AND removes tenant-onboarding/tenants/<name>/ for you to commit —
# keeping Git, the source of truth, in sync. Because the `tenants` Argo app has
# selfHeal=true, push the removal promptly so Argo does not recreate the shell.
#
set -euo pipefail

TENANT=""; GITOPS_ONLY=false; ASSUME_YES=false; DRY_RUN=false; KEEP_KUBECONFIG=false
for arg in "$@"; do
  case "${arg}" in
    --gitops-only)     GITOPS_ONLY=true ;;
    --yes|-y)          ASSUME_YES=true ;;
    --dry-run)         DRY_RUN=true ;;
    --keep-kubeconfig) KEEP_KUBECONFIG=true ;;
    -*)                echo "unknown flag: ${arg}" >&2; exit 1 ;;
    *)                 TENANT="${arg}" ;;
  esac
done

[[ -n "${TENANT}" ]] || { echo "usage: offboard-tenant.sh <name> [--gitops-only] [--yes] [--dry-run] [--keep-kubeconfig]" >&2; exit 1; }
if ! [[ "${TENANT}" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "invalid tenant name '${TENANT}': use lowercase RFC-1123 (a-z, 0-9, -)." >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${ROOT}/tenant-onboarding/tenants/${TENANT}"
NS="tenant-${TENANT}"
KUBECONFIG_FILE="${ROOT}/out/tenant-${TENANT}.kubeconfig"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
run() {
  if ${DRY_RUN}; then
    printf '    DRY:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

git_rm_or_rm() {
  local path="$1"
  local rel="${path#"${ROOT}/"}"
  if git -C "${ROOT}" ls-files --error-unmatch "${rel}" >/dev/null 2>&1; then
    run git -C "${ROOT}" rm -r --quiet -- "${rel}"
  else
    run rm -rf -- "${path}"
  fi
}

matches_tenant_app() {
  local app_file="$1"
  awk -v tenant="${TENANT}" -v ns="${NS}" '
    /^[[:space:]]*project:[[:space:]]*/ {
      value=$0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/["'\''[:space:]]/, "", value)
      if (value == tenant) found=1
    }
    /^[[:space:]]*namespace:[[:space:]]*/ {
      value=$0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/["'\''[:space:]]/, "", value)
      if (value == ns) found=1
    }
    END { exit found ? 0 : 1 }
  ' "${app_file}"
}

APP_FILES=()
if [[ -f "${ROOT}/demo/application.yaml" ]] && matches_tenant_app "${ROOT}/demo/application.yaml"; then
  APP_FILES+=("${ROOT}/demo/application.yaml")
fi

# Guard against offboarding something that was never onboarded: bail only if
# there is no trace at all (no rendered dir, no namespace, no kubeconfig).
HAVE_DIR=false;  [[ -d "${DST}" ]] && HAVE_DIR=true
HAVE_KCFG=false; [[ -f "${KUBECONFIG_FILE}" ]] && HAVE_KCFG=true
HAVE_APP_FILES=false; [[ "${#APP_FILES[@]}" -gt 0 ]] && HAVE_APP_FILES=true
HAVE_NS=false
CLUSTER_REACHABLE=false
if command -v kubectl >/dev/null && { kubectl version -o yaml >/dev/null 2>&1 || kubectl cluster-info >/dev/null 2>&1; }; then
  CLUSTER_REACHABLE=true
  kubectl get namespace "${NS}" >/dev/null 2>&1 && HAVE_NS=true
fi

if ! ${HAVE_DIR} && ! ${HAVE_NS} && ! ${HAVE_KCFG} && ! ${HAVE_APP_FILES}; then
  echo "Nothing to offboard for '${TENANT}': no tenant-onboarding/tenants/${TENANT}/, no demo app targeting ${NS}, no namespace ${NS}, no kubeconfig." >&2
  exit 1
fi

# --- Pre-flight: show exactly what is about to be destroyed ---------------------
log "Offboarding tenant '${TENANT}' will remove:"
${HAVE_DIR}  && echo "    git    : tenant-onboarding/tenants/${TENANT}/  (rendered manifests)"
if ${HAVE_APP_FILES}; then
  echo "    git    : tenant app Argo Application:"
  for app_file in "${APP_FILES[@]}"; do
    echo "             ${app_file#"${ROOT}/"}"
  done
fi
if ${KEEP_KUBECONFIG}; then
  ${HAVE_KCFG} && echo "    local  : out/tenant-${TENANT}.kubeconfig  (KEPT — --keep-kubeconfig)"
else
  ${HAVE_KCFG} && echo "    local  : out/tenant-${TENANT}.kubeconfig  (issued credential)"
fi
if ${GITOPS_ONLY}; then
  echo "    cluster: nothing directly — Argo will prune on push (--gitops-only)"
elif ${CLUSTER_REACHABLE}; then
  if ${HAVE_NS}; then
    echo "    cluster: namespace ${NS} and everything in it:"
    kubectl -n "${NS}" get resourcequota,limitrange,networkpolicy,serviceaccount,rolebinding,deployment,statefulset,pvc --no-headers 2>/dev/null \
      | awk '{print "               "$1}'
    PVC_COUNT="$(kubectl -n "${NS}" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${PVC_COUNT}" != "0" ]] && printf '             \033[1;33m! %s PVC(s) — persistent data will be DELETED\033[0m\n' "${PVC_COUNT}"
  else
    echo "    cluster: namespace ${NS} not present (already gone)"
  fi
  TENANT_APPS="$({
      kubectl -n argocd get applications.argoproj.io \
        -o jsonpath="{range .items[?(@.spec.project=='${TENANT}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null || true
      kubectl -n argocd get applications.argoproj.io \
        -o jsonpath="{range .items[?(@.spec.destination.namespace=='${NS}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null || true
    } | sed '/^$/d' | sort -u)"
  kubectl -n argocd get appproject "${TENANT}" >/dev/null 2>&1 && echo "             appproject/${TENANT} (argocd)"
  [[ -n "${TENANT_APPS}" ]] && echo "             tenant Argo Applications:" && \
    echo "${TENANT_APPS}" | sed 's/^/               application\//'
else
  echo "    cluster: UNREACHABLE — skipping cluster teardown (Argo will prune on push)"
fi

# --- Confirm (destructive) -----------------------------------------------------
if ! ${ASSUME_YES} && ! ${DRY_RUN}; then
  printf '\033[1;31mThis is destructive and irreversible.\033[0m Type the tenant name to confirm [%s]: ' "${TENANT}"
  read -r REPLY || REPLY=""
  [[ "${REPLY}" == "${TENANT}" ]] || { echo "Aborted (got '${REPLY}', expected '${TENANT}')."; exit 1; }
fi

# --- 1. Tear down cluster resources (immediate credential revocation) ----------
# Skipped under --gitops-only (Argo prunes from Git instead) and when no cluster.
if ! ${GITOPS_ONLY} && ${CLUSTER_REACHABLE}; then
  if [[ -n "${TENANT_APPS:-}" ]]; then
    log "Deleting tenant Argo Applications (project ${TENANT} or namespace ${NS})"
    while IFS= read -r app; do
      [[ -n "${app}" ]] && run kubectl -n argocd delete application.argoproj.io "${app}" --ignore-not-found --wait=false
    done <<< "${TENANT_APPS}"
  fi

  if ${HAVE_NS}; then
    log "Deleting namespace ${NS} (revokes the kubeconfig token; removes quota, RBAC, network, workloads, PVCs)"
    run kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  fi

  if [[ -n "${TENANT_APPS:-}" ]] && ! ${DRY_RUN}; then
    log "Waiting briefly for tenant Argo Applications to disappear"
    while IFS= read -r app; do
      [[ -n "${app}" ]] && kubectl -n argocd wait --for=delete "application.argoproj.io/${app}" --timeout=120s >/dev/null 2>&1 || true
    done <<< "${TENANT_APPS}"
  fi

  log "Deleting Argo AppProject ${TENANT}"
  run kubectl -n argocd delete appproject "${TENANT}" --ignore-not-found
fi

# --- 2. Remove Git manifests so Argo stops reconciling them ---------------------
if ${HAVE_DIR}; then
  log "Removing tenant manifests tenant-onboarding/tenants/${TENANT}/"
  git_rm_or_rm "${DST}"
fi

if ${HAVE_APP_FILES}; then
  log "Removing demo Argo Application that targets ${NS}"
  for app_file in "${APP_FILES[@]}"; do
    git_rm_or_rm "${app_file}"
  done
fi

# --- 3. Remove the issued credential from disk ---------------------------------
if ${HAVE_KCFG} && ! ${KEEP_KUBECONFIG}; then
  log "Removing issued kubeconfig out/tenant-${TENANT}.kubeconfig"
  run rm -f -- "${KUBECONFIG_FILE}"
fi

# --- 4. Summary ----------------------------------------------------------------
if ${DRY_RUN}; then
  printf '\n\033[1;33mDry run — nothing was changed.\033[0m\n'
  exit 0
fi

if ${GITOPS_ONLY}; then
  cat <<EOF

Removed tenant Git manifests (cluster untouched). To prune via GitOps:
  git commit -m "offboard tenant ${TENANT}" && git push
Argo then prunes the tenant Applications, namespace, all resources, and AppProject.
EOF
  exit 0
fi

cat <<EOF

$(printf '\033[1;32m')Tenant '${TENANT}' offboarded.$(printf '\033[0m')

  Credential revoked (ServiceAccount deleted with the namespace); the issued
  kubeconfig is removed from disk.

  Keep GitOps in sync (Argo has selfHeal — push promptly so it does not recreate
  the namespace shell from Git):
    git commit -m "offboard tenant ${TENANT}" && git push
EOF
