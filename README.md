# nt548-config

GitOps configuration repository for NT548 task-manager project.

## Structure

- `apps/` — Business application manifests (Kustomize bases & overlays)
- `platform/` — Cluster-wide tooling (ArgoCD apps, monitoring, cert-manager)
- `bootstrap/` — Root App-of-Apps for disaster recovery

## How it works

ArgoCD watches this repo. **DO NOT** `kubectl apply` directly.

To deploy/update:
1. Modify manifests
2. Open PR
3. Merge to `main`
4. ArgoCD auto-syncs within 3 minutes

## Related repos

- **App code:** https://github.com/Devop-Projects/NT548-DevOps

## Bootstrap (cluster recovery)

```bash
kubectl apply -f bootstrap/root-app.yaml
```

This single command will restore all Applications.

## TODO

- [ ] Phase 8: Migrate Terraform from app repo to dedicated repo
