#!/usr/bin/env bash
#
# issue-tenant-kubeconfig.sh <tenant> [ttl] -- mint a NAMESPACE-SCOPED kubeconfig
# for a tenant from their tenant-admin ServiceAccount token. The result grants
# exactly the tenant-admin Role in tenant-<name> and nothing else; hand it to the
# tenant. Re-run to rotate.
#
# Usage:
#   ./tenant-onboarding/issue-tenant-kubeconfig.sh x          # default TTL
#   ./tenant-onboarding/issue-tenant-kubeconfig.sh x 168h     # 7-day token
#
set -euo pipefail

usage() {
  echo "usage: issue-tenant-kubeconfig.sh <tenant> [ttl]" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }

TENANT="$1"
TTL="${2:-${TTL:-720h}}"
NS="tenant-${TENANT}"
SA="tenant-admin"

if ! [[ "${TENANT}" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "invalid tenant name '${TENANT}': use lowercase RFC-1123 (a-z, 0-9, -)." >&2
  exit 1
fi
if ! [[ "${TTL}" =~ ^([0-9]+[smh])+$ ]]; then
  echo "invalid ttl '${TTL}': use a Kubernetes duration such as 1h, 90m, or 168h." >&2
  exit 1
fi
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v base64 >/dev/null || { echo "base64 not found" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/out"
OUT="${OUT_DIR}/tenant-${TENANT}.kubeconfig"
umask 077
mkdir -p "${OUT_DIR}"

kubectl get namespace "${NS}" >/dev/null
kubectl -n "${NS}" get serviceaccount "${SA}" >/dev/null

SERVER="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
CADATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
CAFILE="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
TOKEN="$(kubectl -n "${NS}" create token "${SA}" --duration="${TTL}")"

[[ -n "${SERVER}" ]] || { echo "could not resolve current cluster server from kubeconfig" >&2; exit 1; }
[[ -n "${TOKEN}" ]] || { echo "could not create token for ${NS}/${SA}" >&2; exit 1; }

if [[ -n "${CADATA}" ]]; then
  TLS_LINE="      certificate-authority-data: ${CADATA}"
elif [[ -n "${CAFILE}" && -r "${CAFILE}" ]]; then
  TLS_LINE="      certificate-authority-data: $(base64 < "${CAFILE}" | tr -d '\n')"
elif [[ "${ALLOW_INSECURE_KUBECONFIG:-false}" == "true" ]]; then
  echo "warning: writing kubeconfig with insecure-skip-tls-verify=true" >&2
  TLS_LINE="      insecure-skip-tls-verify: true"
else
  echo "current kubeconfig has no embedded or readable cluster CA; refusing to write an insecure tenant kubeconfig." >&2
  echo "Set ALLOW_INSECURE_KUBECONFIG=true only for a trusted lab cluster." >&2
  exit 1
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
