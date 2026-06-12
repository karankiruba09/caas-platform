#!/usr/bin/env bash
#
# set-cluster.sh -- retarget this GitOps repo at a different fork/cluster by
# rewriting the committed repoURL, base domain, and cluster-issuer in place.
# Commit and push the result BEFORE running bootstrap.sh (Argo reads from Git).
#
# Usage (only pass what changes):
#   REPO_URL=https://github.com/me/caas-platform.git \
#   BASE_DOMAIN=apps.example.com \
#   CLUSTER_ISSUER=letsencrypt-prod \
#   ./platform-onboarding/set-cluster.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Current (committed) values being replaced.
OLD_REPO="https://github.com/karankiruba09/caas-platform.git"
OLD_DOMAIN="apps.k8-cmb1.gcloud.ca"
OLD_ISSUER="letsencrypt-cloudflare"

NEW_REPO="${REPO_URL:-$OLD_REPO}"
NEW_DOMAIN="${BASE_DOMAIN:-$OLD_DOMAIN}"
NEW_ISSUER="${CLUSTER_ISSUER:-$OLD_ISSUER}"

command -v git >/dev/null || { echo "git not found" >&2; exit 1; }
command -v perl >/dev/null || { echo "perl not found" >&2; exit 1; }

replace() { # $1 old  $2 new
  [[ "$1" == "$2" ]] && return 0
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    OLD_VALUE="$1" NEW_VALUE="$2" perl -0pi -e 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' "${ROOT}/${f}"
    echo "  patched ${f}"
  done < <(git -C "${ROOT}" grep -Il -- "$1" || true)
}

echo "==> repoURL  : ${OLD_REPO}  ->  ${NEW_REPO}"
replace "${OLD_REPO}" "${NEW_REPO}"
echo "==> domain   : ${OLD_DOMAIN}  ->  ${NEW_DOMAIN}"
replace "${OLD_DOMAIN}" "${NEW_DOMAIN}"
echo "==> issuer   : ${OLD_ISSUER}  ->  ${NEW_ISSUER}"
replace "${OLD_ISSUER}" "${NEW_ISSUER}"

echo "Done. Review 'git diff', then commit & push before bootstrap.sh."
