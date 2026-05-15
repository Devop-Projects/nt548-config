 Step 6: Tạo Secrets trong namespace mới
⚠️ CỰC KỲ QUAN TRỌNG: Theo plan của bạn, bạn đang tạo Secret với DATABASE_URL=postgres://taskuser:password@... - đây là password sai (không khớp postgres-secrets)! Đừng làm như plan, làm theo cách dưới đây:
bashcd ~/NT548-DevOps

# === Postgres Secret ===
kubectl create secret generic postgres-secrets -n task-manager-dev \
  --from-literal=POSTGRES_PASSWORD='taskpassword-strong'

# === Backend Secret (CHỈ JWT_SECRET, KHÔNG có DATABASE_URL!) ===
# Vì code mới của bạn (database.js) build URL từ components
JWT_SECRET=$(openssl rand -base64 32)
kubectl create secret generic backend-secrets -n task-manager-dev \
  --from-literal=JWT_SECRET="$JWT_SECRET"

# Verify
kubectl get secrets -n task-manager-dev
# Expect:
# NAME               TYPE     DATA   AGE
# backend-secrets    Opaque   1      Xs   ← Chỉ 1 key (JWT_SECRET)
# postgres-secrets   Opaque   1      Xs   ← Chỉ 1 key (POSTGRES_PASSWORD)

kubectl describe secret backend-secrets -n task-manager-dev
# Phải thấy: JWT_SECRET: <bytes>
# KHÔNG có DATABASE_URL
🔧 Step 7: Deploy theo Đúng Thứ tự (Dependency Order)
bashcd ~/NT548-DevOps

# 1. Postgres FIRST (backend depends on it)
kubectl apply -f k8s/base/postgres-statefulset.yaml

# Đợi postgres ready (quan trọng!)
kubectl wait --for=condition=Ready pod/postgres-0 -n task-manager-dev --timeout=180s

# 2. Verify postgres OK
kubectl exec postgres-0 -n task-manager-dev -- \
  pg_isready -U taskuser
# Expect: "accepting connections"

# 3. Backend ConfigMap (must exist before Deployment)
kubectl apply -f k8s/base/backend-configmap.yaml

# 4. Run migration FIRST (creates tables)
kubectl apply -f k8s/base/migrate-job.yaml

# Đợi migration xong
kubectl wait --for=condition=Complete job/db-migrate -n task-manager-dev --timeout=120s

# Check log
kubectl logs -l app=db-migrate -n task-manager-dev
# Expect: "Migration completed successfully"

# Verify tables
kubectl exec postgres-0 -n task-manager-dev -- \
  psql -U taskuser -d taskdb -c "\dt"
# Expect: thấy bảng "users" và "tasks"

# 5. Backend Deployment
kubectl apply -f k8s/base/backend-deployment.yaml

# Đợi rollout
kubectl rollout status deployment/backend -n task-manager-dev --timeout=180s

# 6. Frontend
kubectl apply -f k8s/base/frontend-deployment.yaml
kubectl rollout status deployment/frontend -n task-manager-dev --timeout=120s

# 7. Ingress
kubectl apply -f k8s/base/ingress.yaml

# 8. Final check
kubectl get all -n task-manager-dev
🔧 Step 8: End-to-End Test
bash# Đợi vài giây cho Ingress propagate
sleep 5

# Health check
curl -s http://taskmanager.local:8081/api/health/ready | jq .
# Expect: {"status":"ready","dependencies":{"database":"ok"}}

# Register
curl -X POST http://taskmanager.local:8081/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"vantai","email":"vantai@thesis.com","password":"secure123"}' | jq .
# Expect: {"token":"...","user":{...}}

# Login
curl -X POST http://taskmanager.local:8081/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"vantai@thesis.com","password":"secure123"}' | jq .

echo "🎉 Full E2E test PASSED!"