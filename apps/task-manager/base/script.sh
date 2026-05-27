#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-task-manager-dev}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-taskpassword-strong}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '\n==> %s\n' "$1"
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

require_tools() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl was not found in PATH." >&2
    exit 1
  }

  command -v openssl >/dev/null 2>&1 || {
    echo "openssl was not found in PATH." >&2
    exit 1
  }
}

ensure_secret() {
  local secret_name="$1"
  shift

  if kubectl get secret "$secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Secret $secret_name already exists; keeping current value."
    return
  fi

  run kubectl create secret generic "$secret_name" -n "$NAMESPACE" "$@"
}

require_tools

log "Using Kubernetes context"
run kubectl config current-context

log "Apply namespace"
run kubectl apply -f "$BASE_DIR/namespace.yaml"

log "Clean old stateless workloads from previous dev runs"
run kubectl delete deployment backend frontend -n "$NAMESPACE" --ignore-not-found=true
run kubectl delete job db-migrate -n "$NAMESPACE" --ignore-not-found=true

log "Apply namespace policies and service accounts"
run kubectl apply -f "$BASE_DIR/resourcequota.yaml"
run kubectl apply -f "$BASE_DIR/limitrange.yaml"
run kubectl apply -f "$BASE_DIR/rbac.yaml"

log "Create required secrets if missing"
ensure_secret postgres-secrets \
  --from-literal="POSTGRES_PASSWORD=$POSTGRES_PASSWORD"

JWT_SECRET="$(openssl rand -base64 32)"
ensure_secret backend-secrets \
  --from-literal="JWT_SECRET=$JWT_SECRET"

log "Deploy Postgres"
run kubectl apply -f "$BASE_DIR/postgres-services.yaml"
run kubectl apply -f "$BASE_DIR/postgres-statefulset.yaml"
run kubectl wait --for=condition=Ready pod/postgres-0 -n "$NAMESPACE" --timeout=180s
run kubectl exec postgres-0 -n "$NAMESPACE" -- pg_isready -U taskuser -d taskdb

log "Deploy backend config, service, and migration job"
run kubectl apply -f "$BASE_DIR/backend-configmap.yaml"
run kubectl apply -f "$BASE_DIR/backend-service.yaml"
run kubectl delete job db-migrate -n "$NAMESPACE" --ignore-not-found=true
run kubectl apply -f "$BASE_DIR/migrate-job.yaml"
run kubectl wait --for=condition=Complete job/db-migrate -n "$NAMESPACE" --timeout=180s

log "Deploy backend"
run kubectl apply -f "$BASE_DIR/backend-deployment.yaml"
run kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=180s

log "Deploy frontend"
run kubectl apply -f "$BASE_DIR/frontend-service.yaml"
run kubectl apply -f "$BASE_DIR/frontend-deployment.yaml"
run kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s

log "Apply ingress and network policies"
run kubectl apply -f "$BASE_DIR/ingress.yaml"
run kubectl apply -f "$BASE_DIR/network-policies.yaml"

log "Final status"
run kubectl get all -n "$NAMESPACE" -o wide
run kubectl get ingress,networkpolicy -n "$NAMESPACE"

log "Done"
