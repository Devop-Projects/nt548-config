# nt548-config — GitOps configuration

Declarative desired state for the NT548 task-manager platform running on AWS EKS.
ArgoCD watches this repository and reconciles the cluster against it, so **this repo —
not a `kubectl apply` from someone's laptop — is what the cluster looks like.**

Application source code, container builds and Terraform live in the companion
repository: [`Devop-Projects/NT548-DevOps`](https://github.com/Devop-Projects/NT548-DevOps).

---

## Why two repositories

| | Application repo | This repo |
|---|---|---|
| Contains | App source, Dockerfiles, Terraform, CI workflows | Kubernetes manifests, Helm chart, ArgoCD Applications |
| Changes when | A developer changes behaviour | A release is promoted or the platform is reconfigured |
| Written by | Humans | Humans *and* CI (image tag promotion) |
| Read by | GitHub Actions | ArgoCD |

Keeping them apart means a CI run can promote a new image by committing here without
ever touching application history, and rolling back a deployment is a `git revert` in
this repo rather than a rebuild in the other one.

---

## How a change reaches the cluster

```
Developer pushes to NT548-DevOps
        │
        ▼
GitHub Actions: lint → test → SAST/SCA → build image → push to registry
        │
        │  cross-repo promotion: writes the new image tag into
        │  charts/task-manager/values-aws-dev.yaml in THIS repo
        ▼
   nt548-config @ main
        │
        ▼
ArgoCD (automated sync, prune + selfHeal)
        │
        ▼
Argo Rollouts: Blue/Green
        │
        ├─ preview service receives the new version
        ├─ prePromotionAnalysis queries Prometheus
        │     • prometheus-target-up   ≥ 1
        │     • http-success-rate      ≥ 0.99
        │     • p99-latency            < 0.5 s
        │     (5 samples, 30 s apart, aborts after 2 failures)
        │
        └─ analysis passes → promote to the active service
           analysis fails  → rollout aborts, active service untouched
```

`autoPromotionEnabled` is `false` in dev: the analysis must pass **and** a human must
promote. That keeps the safety of an automated gate without giving up the final say.

---

## Repository layout

```
.
├── bootstrap/
│   ├── root-app.yaml          # App-of-Apps — the only manifest applied by hand
│   └── bootstrap.sh
│
├── platform/                  # Cluster-wide tooling, one ArgoCD Application each
│   ├── argocd/apps/
│   │   ├── kube-prometheus-stack.yaml   # upstream chart, pinned 62.7.0
│   │   ├── argo-rollouts.yaml           # upstream chart, pinned 2.37.7
│   │   ├── grafana-dashboards.yaml
│   │   ├── monitoring-extras.yaml
│   │   └── task-manager-dev.yaml        # the application itself
│   ├── monitoring/
│   │   ├── dashboards/        # RED, node USE and SLO dashboards as ConfigMaps
│   │   ├── prometheus-rules-backend.yaml
│   │   ├── grafana-admin-secret.yaml    # ExternalSecret, not a secret
│   │   └── storageclass-gp3.yaml
│   └── cert-manager/cluster-issuer.yaml
│
├── charts/task-manager/       # ← what ArgoCD actually deploys
│   ├── Chart.yaml
│   ├── values.yaml            # defaults; "" means the value is required
│   ├── values-{dev,aws-dev,staging,prod}.yaml
│   └── templates/
│
└── apps/task-manager/         # Kustomize base + overlays (superseded, see below)
```

---

## Bootstrap and disaster recovery

The cluster is rebuilt from Git with a single command:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

`root-app` is an ArgoCD Application whose source is `platform/argocd/apps/` with
`directory.recurse: true`. Applying it creates every other Application, which in turn
installs monitoring, Argo Rollouts, cert-manager configuration and the workload. Nothing
else is applied manually — that is the whole point of the pattern.

---

## What the chart deploys

`charts/task-manager` is a single chart covering the application and the guardrails
around it. Each template is switched by a feature flag in `values.yaml`:

| Concern | Resources |
|---|---|
| Workload | Backend `Rollout` (Argo Rollouts), frontend `Deployment`, `Service`s, `Ingress` (ALB) |
| Progressive delivery | `AnalysisTemplate` backed by Prometheus queries |
| Configuration | `ConfigMap`, database migration `Job` |
| Secrets | `SecretStore` + `ExternalSecret` — values are pulled from AWS Secrets Manager at runtime, never committed |
| Isolation | `Namespace` with PodSecurity Admission labels, `NetworkPolicy`, `RBAC`, `ServiceAccount` |
| Capacity | `ResourceQuota`, `LimitRange`, `HPA`, `PodDisruptionBudget` |
| Observability | `ServiceMonitor` for backend scraping |

No secret material exists in this repository. `grafana-admin-secret.yaml` and the
`ExternalSecret` templates are *references* to AWS Secrets Manager paths; the External
Secrets Operator resolves them inside the cluster.

---

## Working with this repo

**Do not `kubectl apply` directly.** ArgoCD runs with `selfHeal: true`, so a manual
change is reverted at the next reconciliation — the drift is a symptom, not a fix.

To change the platform:

1. Edit the manifests or chart values.
2. Open a pull request.
3. Merge to `main`.
4. ArgoCD syncs automatically (within ~3 minutes, or trigger a refresh).

To roll back a release, revert the commit that changed the image tag. The cluster
follows Git, so reverting Git *is* the rollback.

### Drift suppression

`task-manager-dev.yaml` carries a deliberate `ignoreDifferences` list. Kubernetes and
Argo Rollouts inject fields after creation — `rollouts-pod-template-hash`,
`controller-uid` and `job-name` labels, `conversionStrategy` on ExternalSecrets — which
ArgoCD would otherwise report as permanent drift. Suppressing exactly those paths keeps
the Application honestly `Synced` instead of permanently yellow, without disabling drift
detection in general.

The sync policy also retries up to 10 times with exponential backoff (30 s → 5 min),
because on a cold cluster the workload can be applied before External Secrets Operator
has finished resolving its secrets. Retrying is the correct answer to an ordering
problem that is temporary by nature.

---

## Known limitations and next steps

- **`apps/` is superseded.** The Kustomize base and overlays predate the migration to
  Helm. No ArgoCD Application references `apps/` any more — the live path is
  `charts/task-manager`. The directory should be deleted or moved under a clearly marked
  `.deprecated/` path; keeping two ways to describe the same workload invites someone to
  edit the wrong one.
- **Only `dev` is wired up.** `values-staging.yaml` and `values-prod.yaml` exist, and
  `apps/task-manager/overlays/` has staging and prod overlays, but
  `platform/argocd/apps/` contains only `task-manager-dev.yaml`. Promoting to another
  environment currently means adding an Application by hand.
- **Image tags are mutable in practice.** CI writes a commit SHA into
  `values-aws-dev.yaml`, which is good, but nothing verifies the image digest. Pinning by
  digest, or verifying a signature with cosign before promotion, would close the gap
  between "the tag we asked for" and "the bytes that ran".
- **Upstream chart versions are pinned** (`kube-prometheus-stack` 62.7.0, `argo-rollouts`
  2.37.7), which is right — but there is no automation to review those pins. Renovate or
  Dependabot against this repo would surface updates instead of letting them drift.
- **Analysis runs only before promotion.** There is no post-promotion analysis and no
  automatic abort once traffic has moved. Adding a `postPromotionAnalysis` step would
  catch regressions that only appear under real load.
