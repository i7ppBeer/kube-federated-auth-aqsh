# kube-federated-auth-aqsh

整合 [kube-federated-auth](https://github.com/rophy/kube-federated-auth)、[kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) 與 [aqsh](https://github.com/rophy/aqsh) 的 Kubernetes Helm Chart，用於多叢集環境下的跨叢集身份驗證與非同步任務執行。

## 目錄

- [元件概述](#元件概述)
- [架構說明](#架構說明)
- [核心原理](#核心原理)
  - [kube-federated-auth](#kube-federated-auth)
  - [kube-auth-proxy](#kube-auth-proxy)
  - [aqsh](#aqsh)
- [存取控制](#存取控制)
  - [authorizedClients](#authorizedclients)
  - [allowed\_groups](#allowed_groups)
  - [比較與關係](#比較與關係)
- [E2E 完整請求流程](#e2e-完整請求流程)
- [網路架構](#網路架構)
- [安裝指南](#安裝指南)
- [設定檔說明](#設定檔說明)
- [使用範例](#使用範例)
- [常見問題](#常見問題)

---

## 元件概述

本 chart（`charts/kube-federated-auth-aqsh`）將以下元件打包成**單一 Deployment**：

| 元件 | 角色 | Port |
|---|---|---|
| **kube-federated-auth** | 跨叢集 SA token 驗證後端（TokenReview API）| 8443 |
| **kube-auth-proxy** | Bearer token → X-Forwarded-* header 轉換的 reverse proxy sidecar | 4180（可選）|
| **aqsh** | 非同步 shell script 任務佇列（HTTP API + Worker）| 8080 |
| **Redis** | aqsh 的 task queue 與 log stream 儲存（獨立 Deployment）| 6379 |

> **kube-auth-proxy 為可選 sidecar**（預設 `kubeAuthProxy.enabled=false`）。  
> 啟用後外部流量應打 `:4180`，proxy 負責驗證 token、注入 header，再轉發至 aqsh `:8080`。

---

## 架構說明

### 整體叢集架構

```
                   ┌──────────────────────────────────────────────────┐
                   │                  central cluster                  │
                   │                                                    │
                   │  ┌──────────────────────────────────────────────┐ │
                   │  │                    Pod                        │ │
                   │  │  ┌──────────────┐   ┌────────────────────┐   │ │
                   │  │  │kube-auth-    │──►│ kube-federated-auth│   │ │
                   │  │  │proxy :4180   │   │ localhost:8443      │   │ │
                   │  │  └──────┬───────┘   └────────────────────┘   │ │
                   │  │         │ X-Forwarded-*                       │ │
                   │  │         ▼                                     │ │
                   │  │  ┌──────────────┐                             │ │
                   │  │  │ aqsh :8080   │                             │ │
                   │  │  └──────────────┘                             │ │
                   │  └──────────────────────────────────────────────┘ │
                   │  ┌──────────┐                                     │
                   │  │  Redis   │  (獨立 Deployment)                  │
                   │  └──────────┘                                     │
                   └──────────────────┬───────────────────────────────┘
                                      │  10.x (central→sub, 單向)
         ┌────────────────────────────┼────────────────────────────┐
         │                            │                            │
┌────────▼────────────────┐           │           ┌───────────────▼─────────┐
│       sub-1-1           │           │           │       sub-2-1           │
│  Pod:                   │◄─100.x───►│           │  Pod:                   │
│   kube-auth-proxy :4180 │           │           │   kube-auth-proxy :4180 │
│   kube-federated-auth   │           │           │   kube-federated-auth   │
│   aqsh                  │           │           │   aqsh                  │
│  Redis (獨立)           │           │           │  Redis (獨立)           │
└─────────────────────────┘           │           └─────────────────────────┘
┌─────────────────────────┐           │           ┌─────────────────────────┐
│       sub-1-2           │           │           │       sub-2-2           │
│  Pod: (同上)            │           │           │  Pod: (同上)            │
└─────────────────────────┘           │           └─────────────────────────┘
      (100.x 互通)                                      (100.x 互通)
      sub-1-x ✗ sub-2-x                                sub-1-x ✗ sub-2-x
```

### Pod 內部架構

```
外部流量
  │  Authorization: Bearer <SA token>
  │  POST /tasks/deploy
  ▼
┌──────────────────────────────────────────────────────────────────┐
│                           Pod                                    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  kube-auth-proxy (:4180)                                 │   │
│  │                                                          │   │
│  │  1. 截取 Authorization Bearer token                      │   │
│  │  2. POST localhost:8443/tokenreviews (帶自身 SA token)   │   │
│  │  3. 移除 Authorization header                            │   │
│  │  4. 注入 X-Forwarded-User/Groups/Extra-Cluster-Name      │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                             │ http://localhost:8080              │
│             ┌───────────────▼────────────┐  ┌────────────────┐  │
│             │  aqsh (:8080)              │  │ kube-federated │  │
│             │  - allowed_groups 檢查      │  │ -auth (:8443)  │  │
│             │  - 推入 Redis queue         │  │ - authorizedCl │  │
│             │  - Worker 執行 script       │  │   ients 白名單 │  │
│             │  - SSE log streaming        │  │ - JWKS 驗簽    │  │
│             └──────────────┬─────────────┘  │ - TokenReview  │  │
│                            │                │   轉發         │  │
│                            ▼                └────────────────┘  │
│             ┌──────────────────────────┐                        │
│             │  Redis (獨立 Deployment)  │                        │
│             │  Asynq queue + Log stream │                        │
│             └──────────────────────────┘                        │
└──────────────────────────────────────────────────────────────────┘
```

### 叢集角色與通訊規則

| 方向 | 網路 | 說明 |
|------|------|------|
| central → sub-* | 10.x | Central 可以驗證所有 sub cluster 的 token |
| sub-1-1 ↔ sub-1-2 | 100.x | 同組 sub cluster 可以互相驗證 |
| sub-2-1 ↔ sub-2-2 | 100.x | 同組 sub cluster 可以互相驗證 |
| sub-1-x ✗ sub-2-x | — | 不同組完全隔離（純設定層，不需 NetworkPolicy）|

---

## 核心原理

### kube-federated-auth

#### 問題背景

Kubernetes 中每個 cluster 都有自己的 ServiceAccount token（JWT 格式）。**Cluster-A 的服務如何驗證 Cluster-B 傳來的 SA token？**

傳統方案的問題：共享 kubeconfig（不安全）、Service Mesh（過重）、手動管理憑證（難維護）。

#### 解決方案：OIDC + TokenReview

每個 K8s cluster 都暴露 OIDC 端點（`/.well-known/openid-configuration`），提供 JWKS（公鑰清單）。SA token 的 JWT 包含：
- `iss`：簽發 cluster 的 OIDC issuer URL
- `sub`：`system:serviceaccount:<namespace>:<name>`
- 使用 cluster 私鑰簽名

kube-federated-auth 啟動時向各 cluster 拉取 JWKS 並快取，收到 token 時：

```
收到 SA token（JWT）
  │
  │  Step 1：本地 JWKS 驗簽
  │           用各 cluster 的公鑰嘗試驗證
  │           → 成功 → 確認 token 來自哪個 cluster
  │           （純本地完成，token 不外傳）
  │
  │  Step 2：轉發 TokenReview 至原始 cluster
  │           → 由原始 cluster API Server 執行權威驗證
  │           → 包含 token 是否已撤銷、bound object 是否存在
  │
  ▼
  回傳：username / groups / extra["authentication.kubernetes.io/cluster-name"]
```

**關鍵設計：**
- Step 1 純本地 → 不需要將 token 傳出就能判斷來源 cluster
- Step 2 確保撤銷檢查由原始 cluster 負責
- Remote cluster 的 bootstrap token 會**自動更新**（預設 7 天 TTL，48 小時前自動更新，儲存在 K8s Secret）
- TokenReview 結果有 LRU + TTL 快取（預設 60 秒），減少跨叢集請求

#### TokenReview API

kube-federated-auth 實作標準 Kubernetes TokenReview API：

```
POST /apis/authentication.k8s.io/v1/tokenreviews
Authorization: Bearer <caller SA token>   ← 呼叫者身份（authorizedClients 在此驗證）
Content-Type: application/json

{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": { "token": "<要驗證的 token>" }
}
```

成功回應：
```json
{
  "status": {
    "authenticated": true,
    "user": {
      "username": "system:serviceaccount:default:my-app",
      "groups": [
        "system:serviceaccounts",
        "system:serviceaccounts:default",
        "system:authenticated"
      ],
      "extra": {
        "authentication.kubernetes.io/cluster-name": ["sub-1-2"]
      }
    }
  }
}
```

---

### kube-auth-proxy

kube-auth-proxy 是一個 **reverse proxy sidecar**，功能類似 oauth2-proxy，但針對 Kubernetes SA token。  
它本身**不做任何 cluster 識別邏輯**，只是把 Bearer token 轉送給 `--token-review-url`，再把結果轉成 header 注入給 upstream。

```
Request (Authorization: Bearer <token>)
  │
  ▼
kube-auth-proxy
  │
  │  POST <--token-review-url>/tokenreviews
  │       body: { token: "<token>" }
  │
  ├─ 驗證失敗 → 401
  ├─ 未授權   → 403
  │
  └─ 驗證成功
       │  移除 Authorization header
       │  注入：
       │    X-Forwarded-User:               system:serviceaccount:<ns>:<name>
       │    X-Forwarded-Groups:             system:serviceaccounts,...
       │    X-Forwarded-Extra-Cluster-Name: <source-cluster-name>
       ▼
     upstream（aqsh :8080）
```

**`--token-review-url` 決定驗證範圍：**

| `--token-review-url` | 能驗哪些 token |
|---|---|
| 不設定（預設 in-cluster API server）| 只有本 cluster 的 SA token |
| `http://localhost:8443`（kube-federated-auth）| 所有已設定 cluster 的 SA token |

本 chart 啟用後固定使用：
```
--upstream=http://localhost:8080          (aqsh)
--token-review-url=http://localhost:8443  (kube-federated-auth)
```

**cluster 識別邏輯完全在 KFA 裡，kube-auth-proxy 不知道有幾個 cluster。**

---

### aqsh

**aqsh = Async Queue for Shell Scripts**，透過 Redis（Asynq library）實作非同步任務佇列。

```
Client
  │  POST /tasks/<name>  { "param": "value" }
  ▼
aqsh API（HTTP server）
  │  1. 驗證輸入參數（對照 tasks.yaml schema）
  │  2. 推入 Redis queue（Asynq）
  │  3. 回傳 task_id
  ▼
aqsh Worker（同 process 或獨立 pod）
  │  1. 從 Redis 取出 task
  │  2. 將 input 轉換為環境變數
  │  3. 執行 shell script（os/exec）
  │  4. stdout/stderr 寫入 Redis Streams（logs:{task_id}）
  │  5. 結果寫入 task result
  ▼
Client
  GET /tasks/<id>        → task 狀態 + 結果
  GET /tasks/<id>/logs   → SSE real-time log streaming
```

**API / Worker 分離模式（`aqsh.mode`）：**

| 值 | 說明 |
|---|---|
| `both`（預設）| 同一個 process 同時處理 API 和 Worker |
| `api` | 只處理 HTTP 請求，不執行任務（適合多副本） |
| `worker` | 只執行任務，無 HTTP（適合 scale out）|

**注入至 script 的環境變數：**

| 變數 | 說明 |
|---|---|
| `AQSH_SUBMITTER` | `X-Forwarded-User` 的值（提交者身份）|
| `AQSH_RESULT_FILE` | 寫入結構化結果的暫存檔路徑 |
| 自定義 | tasks.yaml 中 `input[].env` 對應的欄位 |

---

## 存取控制

本系統有**兩層獨立的存取控制**：

### authorizedClients

**所屬：** kube-federated-auth  
**控制：** 哪些 Kubernetes SA 可以呼叫此 KFA 的 TokenReview API  
**設定：** `values.yaml` → `kubeFederatedAuth.authorizedClients`

格式：`{cluster}/{namespace}/{serviceaccount}`，支援 `*` 萬用字元。

```yaml
kubeFederatedAuth:
  authorizedClients:
    - "sub-1-1/*/*"       # sub-1-1 cluster 的任何 SA
    - "central/*/*"       # central cluster 的任何 SA
    - "*/default/my-app"  # 任何 cluster 的 default/my-app SA
```

KFA 收到請求時先驗證 `Authorization: Bearer` 裡的 **caller token**（呼叫方自身的 SA token），再對照此白名單。未在白名單 → 403。

> 未設定 `authorizedClients` 時，TokenReview endpoint 對所有呼叫者開放。

---

### allowed_groups

**所屬：** aqsh  
**控制：** 哪些 K8s groups 可以觸發某個 task  
**設定：** `charts/kube-federated-auth-aqsh/files/tasks.yaml` → 每個 task 的 `allowed_groups`

```yaml
tasks:
  - name: deploy
    script: /scripts/deploy.sh
    allowed_groups:
      - deploy-team                   # SSO/LDAP group（人類使用者）
      - system:serviceaccounts:ops    # ops namespace 下的所有 SA（機器）
```

aqsh 讀取 `X-Forwarded-Groups` header（由 kube-auth-proxy 注入），比對是否有任一 group 符合。未設定 `allowed_groups` → 對所有通過驗證的身份開放。

**K8s 預設給每個 SA 的 groups：**
- `system:serviceaccounts`（所有 SA）
- `system:serviceaccounts:<namespace>`（同 namespace 的 SA）
- `system:authenticated`

> `allowed_groups` 比對的是 **groups**（`X-Forwarded-Groups`），**不是 username**（`X-Forwarded-User`）。  
> `system:serviceaccount:ns:name` 是 username，不會出現在 groups 中。  
> 若要鎖定單一 SA，需在 kube-auth-proxy 上游加一層 proxy 或使用 Istio AuthorizationPolicy。

---

### 比較與關係

| | `allowed_groups` | `authorizedClients` |
|---|---|---|
| **屬於** | aqsh（per-task）| kube-federated-auth |
| **控制對象** | 誰能觸發 task | 誰能呼叫 TokenReview API |
| **識別來源** | `X-Forwarded-Groups` header | 呼叫方的 SA token（`Authorization: Bearer`）|
| **識別格式** | K8s group 字串 | `{cluster}/{namespace}/{serviceaccount}` |
| **設定位置** | `files/tasks.yaml` | `values.yaml` |
| **不符時** | HTTP 403 | HTTP 403 |

**兩層分工：**

```
外部請求（帶 SA token）
  │
  ▼ kube-auth-proxy → kube-federated-auth
  authorizedClients 檢查
  → proxy 的 SA 有資格呼叫 KFA 嗎？
  │
  ▼ kube-auth-proxy 注入 X-Forwarded-Groups
  │
  ▼ aqsh
  allowed_groups 檢查
  → 請求方的 group 有資格執行此 task 嗎？
```

---

## E2E 完整請求流程

以 **sub-1-2 的 SA（`ns: default, name: my-app`）呼叫 sub-1-1 的 aqsh 執行 `deploy` task** 為例：

```
sub-1-2 / my-app
  │
  │  POST http://<sub-1-1-aqsh-svc>:4180/tasks/deploy
  │  Authorization: Bearer <my-app 的 SA token（由 sub-1-2 簽發）>
  │  Body: { "version": "v1.2.3", "environment": "prod" }
  │
  ▼
[sub-1-1] kube-auth-proxy（sidecar :4180）
  │
  │  Step 1: 截取 Authorization Bearer token
  │  Step 2: 呼叫 TokenReview API
  │    POST http://localhost:8443/apis/authentication.k8s.io/v1/tokenreviews
  │    Authorization: Bearer <kube-auth-proxy 自身的 SA token>  ← authorizedClients 檢查點
  │    Body: { spec: { token: "<my-app 的 SA token>" } }
  │
  ▼
[sub-1-1] kube-federated-auth（localhost:8443）
  │
  │  Step 3: 驗證 kube-auth-proxy 的 SA token
  │    → JWKS 驗簽 → 識別為 "sub-1-1/<ns>/kube-federated-auth-aqsh"
  │    → 對照 authorizedClients 白名單 → ✅
  │  Step 4: 驗證 my-app 的 token（本地 JWKS）
  │    → 識別 issuer 來自 sub-1-2（token 不外傳）
  │  Step 5: 轉發 TokenReview 至 sub-1-2 API Server
  │    → sub-1-2 確認 token 有效、未撤銷
  │  Step 6: 回傳驗證結果
  │    {
  │      authenticated: true,
  │      username: "system:serviceaccount:default:my-app",
  │      groups: ["system:serviceaccounts", "system:serviceaccounts:default", "system:authenticated"],
  │      extra: { "authentication.kubernetes.io/cluster-name": ["sub-1-2"] }
  │    }
  │
  ▼
[sub-1-1] kube-auth-proxy（繼續處理）
  │
  │  Step 7: 移除 Authorization header
  │  Step 8: 注入 headers
  │    X-Forwarded-User:               system:serviceaccount:default:my-app
  │    X-Forwarded-Groups:             system:serviceaccounts,system:serviceaccounts:default,system:authenticated
  │    X-Forwarded-Extra-Cluster-Name: sub-1-2
  │  Step 9: 轉發請求至http://localhost:8080（aqsh）
  │
  ▼
[sub-1-1] aqsh（localhost:8080）
  │
  │  Step 10: 讀取 X-Forwarded-Groups
  │  Step 11: 對照 files/tasks.yaml → deploy.allowed_groups
  │    → "system:serviceaccounts:default" 在白名單 → ✅
  │  Step 12: 驗證輸入參數（version 格式、environment enum）
  │  Step 13: 推入 Redis queue（Asynq）
  │  Step 14: 回傳 { "id": "task_01HXXX", "status": "pending" }
  │
  ▼
[sub-1-1] aqsh Worker
  │
  │  從 Redis 取出 task
  │  注入環境變數：VERSION=v1.2.3, ENVIRONMENT=prod
  │                AQSH_SUBMITTER=system:serviceaccount:default:my-app
  │  執行 /scripts/deploy.sh
  │  stdout/stderr → Redis Streams（logs:task_01HXXX）
  │
  ▼
my-app 取得執行結果
  GET /tasks/task_01HXXX        → 狀態 + 結果
  GET /tasks/task_01HXXX/logs   → SSE real-time log streaming
```

---

## 網路架構

### 網段規劃

| 網段 | 用途 | 方向 |
|---|---|---|
| 10.x | Central ↔ Sub clusters | 單向（central → sub）|
| 100.x | 同組 Sub clusters 之間 | 雙向（sub-1-x ↔ sub-1-x）|

### 隔離機制

不同組（sub-1-x vs sub-2-x）之間**完全隔離**，透過純設定層實現（不需要 NetworkPolicy）：

1. **`remoteClusters`**：sub-1-x 的 KFA 設定中不包含 sub-2-x → 無法識別 sub-2-x 的 token → `token not valid for any configured cluster`
2. **`authorizedClients`**：sub-1-x 的白名單不包含 sub-2-x 的 SA → 呼叫方驗證失敗 → 403

---

## 安裝指南

### 前置準備

- Helm 3.x
- kubectl 可存取各 cluster
- 各 cluster 的 API server 可透過對應網段存取

### 步驟 1：在所有 Sub Clusters 安裝（含 reader）

Reader 是一個輕量 ServiceAccount + RBAC，讓 KFA 可以用它的 token 呼叫 sub cluster 的 TokenReview API 進行權威驗證。

```bash
# 在每個 sub cluster 執行（sub-1-1, sub-1-2, sub-2-1, sub-2-2）
helm install kfa charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --set reader.enabled=true \
  --set kubeFederatedAuth.clusterName=<cluster-name> \
  --set kubeFederatedAuth.clusterRole=sub-same-group
```

使用 values 檔案範本（推薦）：

```bash
# 參考 examples/sub-cluster-values.yaml 建立自訂 values
helm install kfa charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --values my-sub-cluster-values.yaml
```

### 步驟 2：取得各 Sub Cluster 的 CA 憑證與 Bootstrap Token

```bash
# 取得 CA 憑證
kubectl get configmap kube-root-ca.crt \
  -n kube-system \
  -o jsonpath='{.data.ca\.crt}'

# 取得 reader ServiceAccount 的 bootstrap token（Kubernetes 1.24+）
kubectl create token kube-federated-auth-reader \
  --namespace kube-system \
  --duration=8760h   # 1 年；KFA 會在過期前自動更新
```

### 步驟 3：在 Central Cluster 安裝

```bash
# 複製並編輯範本，填入各 sub cluster 的 caCert 和 bootstrapToken
cp examples/combined-central-values.yaml my-central-values.yaml

helm install kfa charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --values my-central-values.yaml
```

### 安裝順序總結

| 步驟 | Central | sub-1-1 | sub-1-2 | sub-2-1 | sub-2-2 |
|------|:-------:|:-------:|:-------:|:-------:|:-------:|
| 1. 安裝（含 reader）| — | ✅ | ✅ | ✅ | ✅ |
| 2. 取得 CA cert / token | — | ✅ | ✅ | ✅ | ✅ |
| 3. 安裝（含 remote clusters）| ✅ | — | — | — | — |

### 啟用 kube-auth-proxy

```bash
helm upgrade kfa charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --reuse-values \
  --set kubeAuthProxy.enabled=true
```

啟用後 aqsh Service 的對外 port 自動切換為 4180。  
需確保 `kubeFederatedAuth.authorizedClients` 包含此 chart SA：

```yaml
kubeFederatedAuth:
  authorizedClients:
    - "<cluster-name>/<namespace>/<serviceAccount.name>"
    # 或
    - "<cluster-name>/*/*"
```

---

## 設定檔說明

### 主要 Values 速查

```yaml
replicaCount: 1

# ── 排程 ──────────────────────────────────────────────────────────────────────
nodeSelector: {}
affinity: {}
tolerations: []
annotations: {}       # Deployment metadata annotations
podAnnotations: {}    # Pod template annotations（e.g. prometheus.io/scrape）
sidecars: []          # 額外注入的 sidecar containers

# ── kube-federated-auth ───────────────────────────────────────────────────────
kubeFederatedAuth:
  clusterRole: central          # central | sub-same-group | sub-isolated
  clusterName: central          # 本 cluster 的名稱（需在所有 cluster 中唯一）

  authorizedClients:
    - "central/*/*"             # 允許 central cluster 所有 SA 呼叫 TokenReview

  cache:
    ttl: 60                     # TokenReview 結果 LRU 快取秒數（0 停用）
    maxEntries: 1000

  renewal:
    interval: "1h"              # 檢查是否需要更新的間隔
    tokenDuration: "168h"       # 向 remote cluster 申請的 token 有效期（7 天）
    renewBefore: "48h"          # 距過期剩不到此時間時主動更新

  localCluster:
    issuer: "https://kubernetes.default.svc.cluster.local"
    caCertPath: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    tokenPath: "/var/run/secrets/kubernetes.io/serviceaccount/token"

  remoteClusters:               # 需要驗證 token 的遠端 cluster 列表
    - name: sub-1-1
      issuer: "https://sub-1-1.example.com:6443"
      apiServer: "https://10.1.1.1:6443"
      caCert: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
      bootstrapToken: "eyJhbGc..."  # 只用一次；KFA 會自動更新並存入 K8s Secret

# ── aqsh ──────────────────────────────────────────────────────────────────────
aqsh:
  mode: both                    # both | api | worker
  identityHeader: "X-Forwarded-User"
  groupsHeader: "X-Forwarded-Groups"
  requireIdentity: true         # false 時跳過身份驗證（僅開發用）

# ── kube-auth-proxy（sidecar）────────────────────────────────────────────────
kubeAuthProxy:
  enabled: false
  image:
    repository: ghcr.io/rophy/kube-auth-proxy
    tag: latest
  port: 4180                    # 對外 port；啟用後 aqsh Service 自動指向此 port

# ── Redis ──────────────────────────────────────────────────────────────────────
redis:
  enabled: true
  persistence:
    enabled: false
    # size: 1Gi
    # storageClass: ""

# ── Vault Secrets（ricoberger/vault-secrets-operator）────────────────────────
vaultSecrets:
  enabled: false
  secrets: []
  # - name: kfa-tokens
  #   path: kvv2/kube-federated-auth/tokens   # 完整 Vault 路徑（含 mount 前綴）
  #   type: Opaque

# ── Reader（sub cluster 啟用）────────────────────────────────────────────────
reader:
  enabled: false
  serviceAccountName: kube-federated-auth-reader
  namespace: kube-system

# ── Istio VirtualService ──────────────────────────────────────────────────────
istio:
  virtualService:
    enabled: false
    hosts: []
    gateways: []
    tls: []
    # tls 範例（SNI-based，kube-federated-auth HTTPS）：
    #  - match:
    #      - port: 443
    #        sniHosts:
    #          - kube-federated-auth.example.com
    #    route:
    #      - destination:
    #          host: <release>-kube-federated-auth
    #          port:
    #            number: 8443
```

### tasks.yaml 設定

任務定義存放於 `charts/kube-federated-auth-aqsh/files/tasks.yaml`，mount 至 `/etc/aqsh/tasks.yaml`：

```yaml
tasks:
  - name: deploy
    script: /scripts/deploy.sh
    description: "Deploy application"
    timeout: 10m
    max_retry: 2
    queue: default

    allowed_groups:
      - deploy-team
      - system:serviceaccounts:ops

    input:
      - name: version
        env: VERSION
        required: true
        type: string
        pattern: '^v?\d+\.\d+\.\d+$'

      - name: environment
        env: ENVIRONMENT
        required: true
        type: string
        enum: [dev, staging, prod]

      - name: dry_run
        env: DRY_RUN
        required: false
        type: bool
        default: "false"
```

### scripts/ 目錄

Shell scripts 存放於 `charts/kube-federated-auth-aqsh/files/scripts/`，mount 至 `/scripts/`（mode 0755）：

```bash
#!/bin/bash
set -euo pipefail

echo "Deploying $VERSION to $ENVIRONMENT (submitter: $AQSH_SUBMITTER)"

# ... 部署邏輯 ...

# 寫入結構化結果（可選）
cat > "$AQSH_RESULT_FILE" << EOF
{
  "deployed_version": "$VERSION",
  "environment": "$ENVIRONMENT"
}
EOF
```

### Vault Secrets

需叢集中已安裝 [ricoberger/vault-secrets-operator](https://github.com/ricoberger/vault-secrets-operator)。  
啟用後 chart 建立 `VaultSecret` CR（`apiVersion: ricoberger.de/v1alpha1`），operator 將 Vault path 的資料同步為同名的 K8s Secret。

典型用途：將 `remoteClusters[].bootstrapToken` 存入 Vault，避免明文出現在 values.yaml 中。

```yaml
vaultSecrets:
  enabled: true
  secrets:
    - name: kfa-tokens       # CR 名稱 = 最終 K8s Secret 名稱
      path: kvv2/kube-federated-auth/tokens
      type: Opaque
```

---

## 使用範例

### 直接呼叫 kube-federated-auth TokenReview

```bash
# 在 sub-1-1 的 pod 中，驗證 sub-1-2 傳來的 token
TOKEN_TO_VERIFY="<sub-1-2 的 SA token>"
MY_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

curl -k -X POST \
  https://kfa-kube-federated-auth.kube-system:8443/apis/authentication.k8s.io/v1/tokenreviews \
  -H "Authorization: Bearer $MY_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"apiVersion\": \"authentication.k8s.io/v1\",
    \"kind\": \"TokenReview\",
    \"spec\": { \"token\": \"$TOKEN_TO_VERIFY\" }
  }"
```

### 透過 kube-auth-proxy 呼叫 aqsh

```bash
# kube-auth-proxy 已啟用，Service 對外 port = 4180
MY_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# 提交任務
TASK_ID=$(curl -s -X POST \
  http://kfa-aqsh.kube-system:4180/tasks/deploy \
  -H "Authorization: Bearer $MY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version": "v1.2.3", "environment": "staging"}' \
  | jq -r .id)

# 查詢狀態
curl http://kfa-aqsh.kube-system:4180/tasks/$TASK_ID

# SSE log streaming
curl http://kfa-aqsh.kube-system:4180/tasks/$TASK_ID/logs
```

### 不啟用 kube-auth-proxy

```bash
# X-Forwarded-* 由外部 proxy（Istio / nginx）注入
curl -X POST http://kfa-aqsh.kube-system:8080/tasks/deploy \
  -H "X-Forwarded-User: system:serviceaccount:default:my-app" \
  -H "X-Forwarded-Groups: system:serviceaccounts,system:serviceaccounts:default,system:authenticated" \
  -H "Content-Type: application/json" \
  -d '{"version": "v1.2.3", "environment": "staging"}'
```

---

## 常見問題

### Q1: reader ServiceAccount 的用途是什麼？

KFA 需要呼叫 sub cluster 的 TokenReview API 做**權威驗證**（確認 token 未被撤銷）。reader SA 擁有 `tokenreviews: create` ClusterRole，提供最小權限的 bootstrap token 給 KFA。KFA 啟動後會申請長期 token 並自動更新，bootstrap token 只用一次。若 K8s Secret 中已有有效 token，bootstrap token 不會被再次使用。

### Q2: bootstrapToken 過期了怎麼辦？

KFA 在 `renewBefore`（預設 48h）前自動更新，更新後儲存於 K8s Secret（`<release>-kube-federated-auth`）。只有 Secret 遺失時才需要重新提供 bootstrap token。

### Q3: Token 快取會不會導致撤銷的 token 仍然有效？

快取（`cache.ttl`，預設 60 秒）儲存 TokenReview 的**結果**。Token 撤銷後最多有 60 秒的延遲。可設 `cache.ttl: 0` 停用快取（會增加每次請求的跨叢集延遲）。

### Q4: 如何確保 sub-1-x 和 sub-2-x 完全隔離？

純設定層隔離，不需 NetworkPolicy：
1. `remoteClusters`：sub-1-x 不設定 sub-2-x → token 無法被識別 → `token not valid for any configured cluster`
2. `authorizedClients`：sub-1-x 不包含 sub-2-x 的 SA → 呼叫方驗證 403

### Q5: allowed_groups 可以設定特定 SA（單一身份）嗎？

不行。`allowed_groups` 對應 `X-Forwarded-Groups`，K8s SA 的 group 最細粒度是 namespace 層級（`system:serviceaccounts:<ns>`）。要鎖定單一 SA，需在 kube-auth-proxy 上游加一層 proxy，或用 Istio AuthorizationPolicy 在 mesh 層攔截。

### Q6: 不啟用 kube-auth-proxy 時如何保護 aqsh？

未啟用 kube-auth-proxy 時，`X-Forwarded-*` header 必須由可信的外部 proxy 注入並防止用戶端偽造。直接暴露 aqsh 而無任何 proxy，任何人都可以偽造 header。建議至少啟用 `kubeAuthProxy.enabled=true` 或使用 Istio PeerAuthentication + AuthorizationPolicy。
