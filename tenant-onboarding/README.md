# Tenant Onboarding

This folder is the platform team's tenant lifecycle workflow. It is intentionally
separate from the demo application: this is access, isolation, policy, and
offboarding.

## What Lives Here

- `onboard-tenant.sh` renders and optionally applies a tenant.
- `offboard-tenant.sh` removes the tenant, its Argo app entry, and credential.
- `issue-tenant-kubeconfig.sh` issues or rotates namespace-scoped access.
- `template/` is the reusable tenant scaffold.
- `tenants/` is the GitOps source of truth for onboarded tenants.
- `policies/` is the Kyverno guardrail set applied to tenant workloads.

## Onboard

```bash
./tenant-onboarding/onboard-tenant.sh <name> [--mesh] [--allow-root] [--gitops-only] [--no-kubeconfig]
```

Example for the WordPress demo tenant:

```bash
./tenant-onboarding/onboard-tenant.sh wordpress --mesh --allow-root
git add tenant-onboarding/tenants/wordpress
git commit -m "onboard tenant wordpress"
git push
```

The command creates:

- namespace `tenant-<name>`
- restricted Pod Security labels by default
- ResourceQuota and LimitRange
- namespace-scoped tenant-admin ServiceAccount, Role, and RoleBinding
- default-deny NetworkPolicy with ingress/monitoring exceptions
- Argo CD AppProject scoped to the tenant namespace
- `out/tenant-<name>.kubeconfig` for tenant access

## Offboard

```bash
./tenant-onboarding/offboard-tenant.sh <name>
```

Offboarding deletes the tenant Argo Applications, AppProject, namespace,
rendered tenant manifests, matching demo Argo Application, and issued
kubeconfig. Use `--dry-run` to inspect the removal plan first.

Pure GitOps offboarding:

```bash
./tenant-onboarding/offboard-tenant.sh <name> --gitops-only
git commit -m "offboard tenant <name>"
git push
```
