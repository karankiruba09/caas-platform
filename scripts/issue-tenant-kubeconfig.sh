#!/usr/bin/env bash
#
# issue-tenant-kubeconfig.sh <tenant> [ttl] -- mint a NAMESPACE-SCOPED kubeconfig
# for a tenant from their tenant-admin ServiceAccount token. The result grants
# exactly the tenant-admin Role in tenant-<name> and nothing else; hand it to the
# tenant. Re-run to rotate.
#
# Usage:
#   ./scripts/issue-tenant-kubeconfig.sh x          # default TTL
#   ./scripts/issue-tenant-kubeconfig.sh x 168h     # 7-day token
#
set -euo pipefail

TENANT="${1:?usage: issue-tenant-kubeconfig.sh <tenant> [ttl]}"
TTL="${2:-${TTL:-720h}}"
NS="tenant-${TENANT}"
SA="tenant-admin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/out"
OUT="${OUT_DIR}/tenant-${TENANT}.kubeconfig"
mkdir -p "${OUT_DIR}"

kubectl get namespace "${NS}" >/dev/null
kubectl -n "${NS}" get serviceaccount "${SA}" >/dev/null

SERVER="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
CADATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
TOKEN="$(kubectl -n "${NS}" create token "${SA}" --duration="${TTL}")"

if [[ -n "${CADATA}" ]]; then
  TLS_LINE="      certificate-authority-data: ${CADATA}"
else
  TLS_LINE="      insecure-skip-tls-verify: true"
fi

cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: caas
    cluster:
      server: ${SERVER}
${TLS_LINE}
contexts:
  - name: ${NS}
    context:
      cluster: caas
      namespace: ${NS}
      user: tenant-${TENANT}
current-context: ${NS}
users:
  - name: tenant-${TENANT}
    user:
      token: ${TOKEN}
EOF
chmod 600 "${OUT}"

cat <<EOF
Issued namespace-scoped kubeconfig:
  file       : ${OUT}
  namespace  : ${NS}   (default context namespace)
  identity   : ServiceAccount ${NS}/${SA}  -> Role tenant-admin
  TTL         : ${TTL} requested (the API server may cap this)

Hand this file to the tenant. They use it with:
  KUBECONFIG=${OUT} kubectl get pods
It works only inside ${NS}; it cannot touch other namespaces or cluster scope.

NOTE: this file contains a bearer token — it is gitignored (out/). Never commit it.
EOF
