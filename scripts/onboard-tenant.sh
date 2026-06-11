#!/usr/bin/env bash
#
# onboard-tenant.sh <name> -- render the tenant template into tenants/<name>/.
# Commit and push the result; Argo CD's "tenants" Application applies it and the
# tenant (namespace + quota + limits + RBAC + netpol + AppProject) comes to life.
#
# Usage:
#   ./scripts/onboard-tenant.sh acme
#
set -euo pipefail

TENANT="${1:?usage: onboard-tenant.sh <tenant-name>}"
if ! [[ "${TENANT}" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "Invalid tenant name '${TENANT}': use lowercase RFC-1123 (a-z, 0-9, -)." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/tenants/_template"
DST="${ROOT}/tenants/${TENANT}"

if [[ -e "${DST}" ]]; then
  echo "tenants/${TENANT} already exists — aborting." >&2
  exit 1
fi

mkdir -p "${DST}"
for f in "${SRC}"/*.yaml; do
  base="$(basename "$f")"
  sed "s/__TENANT__/${TENANT}/g" "$f" > "${DST}/${base}"
done

echo "Rendered tenant '${TENANT}' -> tenants/${TENANT}/"
ls -1 "${DST}" | sed 's/^/  /'
cat <<EOF

Next:
  git add tenants/${TENANT}
  git commit -m "onboard tenant ${TENANT}"
  git push
  # Argo CD applies it within ~1 minute. Verify:
  kubectl get ns tenant-${TENANT} --show-labels
  kubectl -n tenant-${TENANT} get resourcequota,limitrange,networkpolicy,rolebinding
  kubectl -n argocd get appproject ${TENANT}
EOF
