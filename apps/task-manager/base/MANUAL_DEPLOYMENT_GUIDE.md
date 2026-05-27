# Manual Kubernetes Deployment Guide

Guide này dùng để học cách deploy app Task Manager bằng từng lệnh `kubectl` thủ công. File `script.sh` chỉ để chạy tự động toàn bộ flow; còn file này giải thích từng bước, vì sao phải chạy theo thứ tự đó, và nên quan sát gì.

Thư mục manifest:

```bash
cd ~/nt548-config
BASE=apps/task-manager/base
NS=task-manager-dev
```

## 0. Kiểm tra cluster đang dùng

```bash
kubectl config current-context
```

Lệnh này giúp tránh deploy nhầm cluster. Mọi lệnh `kubectl` sẽ chạy vào context hiện tại.

## 1. Tạo namespace

```bash
kubectl apply -f $BASE/namespace.yaml
kubectl get namespace $NS
```

Namespace là vùng tách biệt logic trong cluster. Các object như Pod, Service, Secret, ConfigMap, Deployment của app đều nằm trong `task-manager-dev`, nên namespace phải có trước.

Nếu chưa tạo namespace mà apply Deployment, bạn sẽ gặp lỗi:

```text
namespaces "task-manager-dev" not found
```

## 2. Dọn workload cũ trong môi trường lab

```bash
kubectl delete deployment backend frontend -n $NS --ignore-not-found=true
kubectl delete job db-migrate -n $NS --ignore-not-found=true
```

Bước này chỉ dành cho dev/lab. Trước đó bạn đã từng apply riêng `backend-deployment.yaml`, nên cluster có thể còn `Deployment/backend` bị kẹt. Nếu không dọn, khi tạo `backend-sa`, Deployment cũ có thể bắt đầu tạo Pod ngay, làm bạn khó quan sát đúng thứ tự.

Bước này không xóa Postgres StatefulSet hoặc PVC, vì đó là phần dữ liệu.

## 3. Tạo ResourceQuota và LimitRange

```bash
kubectl apply -f $BASE/resourcequota.yaml
kubectl apply -f $BASE/limitrange.yaml
kubectl get resourcequota,limitrange -n $NS
```

`ResourceQuota` giới hạn tổng tài nguyên trong namespace, ví dụ số Pod, tổng CPU, tổng memory, số Secret, số ConfigMap.

`LimitRange` đặt request/limit mặc định cho container nếu manifest nào đó quên khai báo. Nên tạo sớm để các workload sau được validate theo policy của namespace.

## 4. Tạo ServiceAccount

```bash
kubectl apply -f $BASE/rbac.yaml
kubectl get serviceaccount -n $NS
```

Backend, frontend và postgres không dùng `default` ServiceAccount. Manifest khai báo:

```yaml
serviceAccountName: backend-sa
serviceAccountName: frontend-sa
serviceAccountName: postgres-sa
```

Nếu thiếu `backend-sa`, Deployment vẫn tạo được ReplicaSet, nhưng ReplicaSet không tạo được Pod. Đây là lỗi bạn đã gặp:

```text
serviceaccount "backend-sa" not found
```

## 5. Tạo Secret

```bash
kubectl create secret generic postgres-secrets \
  -n $NS \
  --from-literal=POSTGRES_PASSWORD='taskpassword-strong'
```

```bash
JWT_SECRET=$(openssl rand -base64 32)

kubectl create secret generic backend-secrets \
  -n $NS \
  --from-literal=JWT_SECRET="$JWT_SECRET"
```

Kiểm tra metadata của Secret:

```bash
kubectl get secrets -n $NS
```

Không nên in giá trị Secret ra terminal nếu không cần.

Postgres cần `POSTGRES_PASSWORD` để khởi tạo database. Backend cũng cần password này để kết nối DB. Backend cần thêm `JWT_SECRET` để ký token đăng nhập.

Secret khác ConfigMap ở chỗ Secret dùng cho dữ liệu nhạy cảm như password, token, key.

## 6. Tạo Service cho Postgres

```bash
kubectl apply -f $BASE/postgres-services.yaml
kubectl get svc -n $NS
```

File này tạo 2 Service:

```text
postgres-headless
postgres
```

`postgres-headless` dùng cho StatefulSet để có DNS ổn định, ví dụ:

```text
postgres-0.postgres-headless.task-manager-dev.svc.cluster.local
```

`postgres` là ClusterIP Service để backend connect ngắn gọn bằng:

```text
DB_HOST=postgres
```

## 7. Tạo Postgres StatefulSet

```bash
kubectl get storageclass
kubectl apply -f $BASE/postgres-statefulset.yaml
kubectl wait --for=condition=Ready pod/postgres-0 -n $NS --timeout=180s
kubectl exec postgres-0 -n $NS -- pg_isready -U taskuser -d taskdb
```

Postgres là workload có state, nên dùng `StatefulSet` và PVC thay vì Deployment. Pod có tên ổn định là:

```text
postgres-0
```

Nếu `postgres-0` bị Pending lâu, kiểm tra StorageClass. Manifest đang dùng:

```yaml
storageClassName: standard
```

Nếu cluster không có StorageClass `standard`, PVC sẽ không bind được volume.

## 8. Tạo ConfigMap cho backend

```bash
kubectl apply -f $BASE/backend-configmap.yaml
kubectl describe configmap backend-config -n $NS
```

ConfigMap chứa config không nhạy cảm:

```text
DB_HOST
DB_PORT
DB_NAME
DB_USER
PORT
LOG_LEVEL
```

Backend Deployment dùng:

```yaml
envFrom:
- configMapRef:
    name: backend-config
```

Vì vậy ConfigMap phải tồn tại trước khi Pod backend được tạo.

## 9. Tạo Service cho backend

```bash
kubectl apply -f $BASE/backend-service.yaml
kubectl get svc backend -n $NS
kubectl get endpoints backend -n $NS
```

Backend Service tạo stable DNS và virtual IP cho backend. Service chọn Pod bằng selector:

```yaml
selector:
  app: backend
```

Ở thời điểm này endpoints có thể rỗng, vì backend Pod chưa được tạo. Sau khi backend Pod Ready, endpoints sẽ xuất hiện.

## 10. Chạy database migration

```bash
kubectl delete job db-migrate -n $NS --ignore-not-found=true
kubectl apply -f $BASE/migrate-job.yaml
kubectl wait --for=condition=Complete job/db-migrate -n $NS --timeout=180s
kubectl logs -l app=db-migrate -n $NS --tail=100
```

Migration nên chạy sau khi Postgres Ready và trước khi backend nhận traffic. Lý do là backend thường cần database schema đã tồn tại trước khi xử lý request.

`Job` khác `Deployment`: Job chạy đến khi hoàn thành rồi dừng. Nếu Job cũ đã tồn tại, `kubectl apply` không nhất thiết chạy lại migration, nên trong lab ta xóa Job cũ trước.

## 11. Tạo backend Deployment

```bash
kubectl apply -f $BASE/backend-deployment.yaml
kubectl rollout status deployment/backend -n $NS --timeout=180s
```

Đến bước này, các dependency của backend đã có:

```text
namespace
backend-sa
postgres-secrets
backend-secrets
backend-config
postgres service
postgres pod ready
database migration complete
backend service
```

Deployment sẽ tạo ReplicaSet, ReplicaSet tạo Pod.

Kiểm tra:

```bash
kubectl get deploy backend -n $NS -o wide
kubectl get rs -n $NS -l app=backend -o wide
kubectl get pods -n $NS -l app=backend -o wide --show-labels
kubectl get endpoints backend -n $NS
```

Quan hệ cần hiểu:

```text
Deployment -> ReplicaSet -> Pod
```

Với manifest hiện tại:

```yaml
replicas: 2
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

Nghĩa là Kubernetes luôn cố giữ đủ 2 backend Pod Ready. Khi rolling update, nó được phép tạo thêm tối đa 1 Pod mới và không được làm mất Pod Ready nào trước khi Pod mới sẵn sàng.

## 12. Tạo frontend Service và Deployment

```bash
kubectl apply -f $BASE/frontend-service.yaml
kubectl apply -f $BASE/frontend-deployment.yaml
kubectl rollout status deployment/frontend -n $NS --timeout=180s
kubectl get deploy,rs,pods,svc -n $NS -l app=frontend -o wide
```

Frontend cũng dùng ServiceAccount riêng `frontend-sa`. Service tạo stable target cho traffic, Deployment tạo Pod nginx thật sự.

## 13. Tạo Ingress và NetworkPolicy

```bash
kubectl apply -f $BASE/ingress.yaml
kubectl apply -f $BASE/network-policies.yaml
kubectl get ingress -n $NS
kubectl get networkpolicy -n $NS
```

Ingress expose app ra ngoài cluster thông qua ingress controller.

NetworkPolicy giới hạn traffic giữa các Pod. Nên apply sau khi core app chạy ổn để dễ debug từng lớp: database, backend, frontend, network.

## 14. Kiểm tra tổng thể

```bash
kubectl get all -n $NS -o wide
kubectl get events -n $NS --sort-by=.lastTimestamp
```

`kubectl get all` giúp nhìn nhanh Pod, Service, Deployment, ReplicaSet, StatefulSet, Job.

`events` là nơi nên xem đầu tiên khi gặp lỗi:

```text
Pending
ImagePullBackOff
CrashLoopBackOff
CreateContainerConfigError
Readiness probe failed
ServiceAccount not found
Secret not found
PVC Pending
```

## Rolling update

Xem lịch sử:

```bash
kubectl rollout history deployment/backend -n $NS
```

Đổi image để trigger rolling update:

```bash
kubectl annotate deployment/backend \
  kubernetes.io/change-cause="Update backend image" \
  -n $NS --overwrite

kubectl set image deployment/backend \
  backend=doanvantai/nt548-backend:newtag \
  -n $NS
```

Quan sát:

```bash
kubectl rollout status deployment/backend -n $NS
kubectl get rs -n $NS -l app=backend -w
kubectl get pods -n $NS -l app=backend -w
```

Nếu `newtag` không tồn tại, Pod mới sẽ bị `ImagePullBackOff`. Khi đó debug:

```bash
kubectl describe pod <pod-name> -n $NS
kubectl get events -n $NS --sort-by=.lastTimestamp
```

## Rollback

```bash
kubectl rollout undo deployment/backend -n $NS
kubectl rollout status deployment/backend -n $NS
kubectl get rs -n $NS -l app=backend
```

Rollback làm Deployment quay lại Pod template cũ. ReplicaSet cũ scale up, ReplicaSet mới scale down.

Rollback về revision cụ thể:

```bash
kubectl rollout history deployment/backend -n $NS
kubectl rollout undo deployment/backend -n $NS --to-revision=<revision-number>
```

## Self-healing

Xóa backend Pod:

```bash
kubectl delete pod -n $NS -l app=backend
kubectl get pods -n $NS -l app=backend -w
```

ReplicaSet sẽ tạo Pod mới để đưa số lượng về `replicas=2`.

Đây là self-healing: bạn không giữ Pod sống bằng tay. Bạn khai báo desired state trong Deployment, Kubernetes tự kéo cluster về trạng thái đó.

## Debug nhanh

```bash
kubectl describe deploy backend -n $NS
kubectl describe rs -n $NS -l app=backend
kubectl describe pod <pod-name> -n $NS
kubectl logs <pod-name> -n $NS
kubectl get events -n $NS --sort-by=.lastTimestamp
```

Khi không thấy Pod nào dù Deployment đã created:

```bash
kubectl get deploy,rs,pods -n $NS
kubectl describe rs -n $NS -l app=backend
kubectl get events -n $NS --sort-by=.lastTimestamp
```

Trường hợp của bạn trước đó là:

```text
Deployment created
ReplicaSet created
Pod not created
Reason: serviceaccount "backend-sa" not found
```

Vì vậy phải tạo `rbac.yaml` trước `backend-deployment.yaml`.
