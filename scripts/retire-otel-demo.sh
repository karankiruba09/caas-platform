#!/usr/bin/env bash
#
# retire-otel-demo.sh -- decommission the original heavy "otel-demo" POC
# (storefront + kafka + opensearch + load-generator + bundled observability).
# The CaaS platform replaces it with a lean OTel Collector + Jaeger in the
# platform-observability namespace.
#
# Safe to run before or after bootstrap.sh. Idempotent.
#
#   ./scripts/retire-otel-demo.sh           # uninstall + delete namespace
#   DRY_RUN=true ./scripts/retire-otel-demo.sh   # show what would happen
#
set -euo pipefail

NAMESPACE="${OTEL_DEMO_NAMESPACE:-otel-demo}"
RELEASE="${OTEL_DEMO_RELEASE:-otel-demo}"
DRY_RUN="${DRY_RUN:-false}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "DRY: $*"; else eval "$*"; fi; }

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace ${NAMESPACE} not found — nothing to retire."
  exit 0
fi

log "Resources currently in ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get deploy,sts,svc,ingress 2>/dev/null | head -40 || true

log "Uninstalling Helm release ${RELEASE}"
run "helm uninstall ${RELEASE} --namespace ${NAMESPACE} || true"

log "Deleting namespace ${NAMESPACE} (removes leftover ingress, certs, PVCs)"
run "kubectl delete namespace ${NAMESPACE} --wait=true"

log "Done. The CaaS platform's observability lives in 'platform-observability'."
