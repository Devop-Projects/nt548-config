#!/usr/bin/env bash
# ============================================================================
# bootstrap/bootstrap.sh
# ============================================================================
# Bootstrap ArgoCD applications in CORRECT ORDER để tránh dependency hell.
#
# Vì sao cần script này thay vì kubectl apply -f bootstrap/root-app.yaml?
#
# Vấn đề: Root app tạo MỌI Application cùng lúc. Khi cluster mới recreate:
#   - ExternalSecrets Operator chưa fully ready (~30-60s)
#   - kube-prometheus-stack chưa install CRDs (ServiceMonitor) (~3 min)
#   - task-manager Job ngay lập tức chạy → fail vì thiếu Secret
#
# Giải pháp: Apply theo TIER (tầng), đợi mỗi tier ready trước khi tiếp.
#   Tier 0: Platform addons (ESO, monitoring stack) — slow CRDs
#   Tier 1: Tools (argo-rollouts) — depends on cluster basic
#   Tier 2: Apps (task-manager) — depends on tier 0 secrets ready
#
# Usage:
#   ./bootstrap/bootstrap.sh             # Full bootstrap
#   ./bootstrap/bootstrap.sh --tier 0    # Only platform
#   ./bootstrap/bootstrap.sh --skip-wait # Don't wait between tiers (advanced)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_DIR="$CONFIG_REPO/platform/argocd/apps"

# ─── Args ───────────────────────────────────────────
TIER_FILTER=""
SKIP_WAIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --tier) TIER_FILTER="$2"; shift 2 ;;
    --skip-wait) SKIP_WAIT=true; shift ;;
    --help|-h) head -30 "$0" | grep "^#"; exit 0 ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; exit 1 ;;
  esac
done

# ─── Helpers ────────────────────────────────────────
log_info()    { echo -e "${BLUE}► $1${NC}"; }
log_ok()      { echo -e "${GREEN}✓ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠ $1${NC}"; }
log_err()     { echo -e "${RED}✗ $1${NC}" >&2; }

wait_for_app() {
  local app_name="$1"
  local timeout="${2:-600}"
  local elapsed=0
  local interval=15

  log_info "Waiting for application '$app_name' to be Synced + Healthy (max ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    local sync_status
    local health_status
    sync_status=$(kubectl get application "$app_name" -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    health_status=$(kubectl get application "$app_name" -n argocd \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

    echo "  [${elapsed}s] Sync=$sync_status, Health=$health_status"

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
      log_ok "$app_name ready"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  log_err "Timeout waiting for $app_name"
  kubectl describe application "$app_name" -n argocd | tail -30
  return 1
}

apply_tier() {
  local tier="$1"
  shift
  local apps=("$@")

  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  TIER $tier${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

  for app_file in "${apps[@]}"; do
    local app_path="$APPS_DIR/$app_file"
    if [ ! -f "$app_path" ]; then
      log_warn "$app_file not found, skipping"
      continue
    fi

    log_info "Applying $app_file..."
    kubectl apply -f "$app_path"
    log_ok "Applied $app_file"
  done

  if [ "$SKIP_WAIT" = false ]; then
    # Đợi mỗi app trong tier ready trước khi sang tier tiếp
    for app_file in "${apps[@]}"; do
      if [ ! -f "$APPS_DIR/$app_file" ]; then continue; fi
      local app_name
      app_name=$(yq eval '.metadata.name' "$APPS_DIR/$app_file")
      wait_for_app "$app_name" 600
    done
  fi
}

# ─── Pre-flight ─────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${BLUE}  ArgoCD Tiered Bootstrap${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

# Verify cluster reachable
if ! kubectl get nodes >/dev/null 2>&1; then
  log_err "Cluster unreachable. Run: aws eks update-kubeconfig --name devops-dev --region ap-southeast-1"
  exit 1
fi

# Verify ArgoCD installed
if ! kubectl get namespace argocd >/dev/null 2>&1; then
  log_err "ArgoCD not installed. Install first: see README.md"
  exit 1
fi

log_ok "Pre-flight checks passed"

# ─── TIER 0: Platform (ESO already installed by Terraform) ───
# Note: ExternalSecrets Operator được install bởi Terraform addon, không qua ArgoCD.
# Tier 0 chỉ verify ESO ready.
if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "0" ]; then
  echo ""
  log_info "TIER 0: Verifying ExternalSecrets Operator (installed by Terraform)..."

  if kubectl wait --for=condition=Available deployment/external-secrets \
       -n external-secrets --timeout=180s 2>/dev/null; then
    log_ok "ESO ready"
  else
    log_err "ESO not ready. Check: kubectl get pods -n external-secrets"
    exit 1
  fi

  # Test CRDs available
  if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    log_ok "ESO CRDs installed"
  else
    log_err "ESO CRDs missing"
    exit 1
  fi
fi

# ─── TIER 1: Monitoring + Tools ──────────────────────
if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "1" ]; then
  apply_tier 1 \
    "monitoring-extras.yaml" \
    "kube-prometheus-stack.yaml" \
    "argo-rollouts.yaml"
fi

# ─── TIER 2: Application ────────────────────────────
if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "2" ]; then
  apply_tier 2 \
    "task-manager-dev.yaml"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Bootstrap complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
log_info "Next steps:"
echo "  1. make k8s-wait-alb       # Wait for ALB"
echo "  2. make tf-apply-dns-phase2 # Route53 → ALB"
echo "  3. make verify              # Test endpoint"