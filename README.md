# kube-federated-auth-aqsh

整合 `kube-federated-auth` 和 `aqsh` 的 Kubernetes Helm Charts，用於多叢集環境下的跨叢集身份驗證與非同步任務執行。

## 目錄

- [專案概述](#專案概述)
- [架構說明](#架構說明)
- [核心原理](#核心原理)
  - [kube-federated-auth 運作原理](#kube-federated-auth-運作原理)
  - [aqsh 運作原理](#aqsh-運作原理)
  - [authorized_clients 說明](#authorized_clients-說明)
- [網路架構](#網路架構)
- [安裝指南](#安裝指南)
  - [前置準備](#前置準備)
  - [安裝步驟](#安裝步驟)
- [設定檔說明](#設定檔說明)
- [使用範例](#使用範例)
- [常見問題](#常見問題)

## 專案概述

本專案提供四個 Helm charts：

1. **kube-federated-auth-aqsh** ⭐ **(推薦) 合併版**：將所有元件整合在同一個 Deployment 中，一次安裝搞定
2. **kube-federated-auth**: Kubernetes 聯邦身份驗證伺服器（獨立安裝）
3. **kube-federated-auth-reader**: 輕量級 ServiceAccount 與 RBAC 設定（供 sub cluster 使用，獨立安裝）
4. **aqsh**: 非同步 Shell 腳本執行系統（含 Redis，獨立安裝）

### 合併版 vs 獨立版

| | 合併版 (`kube-federated-auth-aqsh`) | 獨立版（三個 chart 分開） |
|---|---|---|
| **Deployment 數量** | 1（含兩個 container）+ Redis | 2 + Redis |
| **安裝指令** | 1 條 helm install | 3 條 helm install |
| **適合場景** | 簡單部署、小型環境 | 需要獨立擴縮、進階控制 |
| **reader 整合** | 內建（`reader.enabled=true`）| 需單獨安裝 |

## 架構說明

### 整體架構圖

```
                        ┌─────────────────────────────────────────┐
                        │           central cluster                │
                        │                                          │
                        │   ┌─────────────────────┐               │
                        │   │  kube-federated-auth │               │
                        │   │  (knows all 4 subs)  │               │
                        │   └─────────────────────┘               │
                        │   ┌──────┐  ┌──────────┐               │
                        │   │aqsh  │  │  Redis   │               │
                        │   └──────┘  └──────────┘               │
                        └────────────┬────────────────────────────┘
                                     │  10.x (central→sub, 單向)
              ┌──────────────────────┼──────────────────────┐
              │                      │                       │
   ┌──────────▼──────────┐           │           ┌──────────▼──────────┐
   │      sub-1-1        │           │           │      sub-2-1        │
   │  kube-federated-auth│◄──100.x──►│           │  kube-federated-auth│◄─100.x─►
   │  aqsh + Redis       │           │           │  aqsh + Redis       │
   └─────────────────────┘           │           └─────────────────────┘
   ┌─────────────────────┐           │           ┌─────────────────────┐
   │      sub-1-2        │           │           │      sub-2-2        │
   │  kube-federated-auth│           │           │  kube-federated-auth│
   │  aqsh + Redis       │           │           │  aqsh + Redis       │
   └─────────────────────┘           │           └─────────────────────┘
         (100.x 互通)                             (100.x 互通)
         sub-1-x ✗ sub-2-x           │           sub-1-x ✗ sub-2-x
```

### 叢集角色與通訊規則

| 方向 | 網路 | 說明 |
|------|------|------|
| central → sub-* | 10.x | Central 可以驗證所有 sub cluster 的 token |
| sub-1-1 ↔ sub-1-2 | 100.x | 同組的 sub cluster 可以互相驗證 |
| sub-2-1 ↔ sub-2-2 | 100.x | 同組的 sub cluster 可以互相驗證 |
| sub-1-x ✗ sub-2-x | 禁止 | 不同組之間完全隔離 |

## 核心原理

### kube-federated-auth 運作原理

#### 問題背景

Kubernetes 中每個 cluster 都有自己的 ServiceAccount (SA) token（格式為 JWT）。問題在於：**cluster-A 的服務如何驗證 cluster-B 傳來的 SA token 是否真實？**

傳統解決方案的問題：
- 共享 kubeconfig：不安全
- Service Mesh：過於複雜
- 手動管理憑證：難以維護

#### kube-federated-auth 解決方案

使用 **OIDC + Kubernetes TokenReview API** 自動化解決跨叢集身份驗證。

#### 核心流程

```
cluster-b 的 client
    │
    │  1. 帶著自己的 SA token 發送 request
    ▼
cluster-a 的服務
    │
    │  2. 呼叫 kube-federated-auth 的 TokenReview API
    ▼
kube-federated-auth（運行在 cluster-a）
    │
    │  3. 本地使用 JWKS 驗證簽名 → 偵測此 token 來自哪個 cluster
    │     （不需要外傳 token，純本地判斷）
    │
    │  4. 將 TokenReview 轉發至 cluster-b 的 API Server
    │     → 讓 cluster-b 執行權威驗證（包含撤銷檢查）
    ▼
    回傳結果給服務（包含 cluster-name extra field）
```

**關鍵設計：**
- Step 3 是純本地 JWKS 驗簽 → **不需要將 token 傳出就能知道它來自哪個 cluster**
- Step 4 是真正的授權驗證（由原始 cluster 負責，確保 token 未被撤銷）
- Token 會**自動更新**（預設 7 天 TTL，48 小時前自動更新）

#### Kubernetes SA Token 結構

每個 SA token 是一個 JWT，包含：
- `iss`（issuer）：哪個 cluster 簽發的（例如 `https://kubernetes.default.svc.cluster.local`）
- `sub`：`system:serviceaccount:namespace:name`
- 使用 cluster 私鑰簽名

每個 K8s cluster 都有 OIDC endpoint（`/.well-known/openid-configuration`），可以取得 JWKS（公鑰列表）用來驗證 JWT 簽名。

### aqsh 運作原理

**aqsh = Async Queue for Shell Scripts**

```
Client → HTTP API Pod → Redis (Asynq queue) → Worker Pod → 執行 shell script
                                                           → 將 log stream 寫回 Redis
Client ← SSE log streaming ← API Pod ← Redis Stream
```

架構特點：
- **API pod** 和 **worker pod** 可以分離（`AQSH_MODE=api` / `worker` / `both`）
- 使用 Redis Streams 進行 real-time log streaming
- `tasks.yaml` 定義任務：腳本路徑、輸入參數、驗證規則
- 支援 `X-Forwarded-User` / `X-Forwarded-Groups` header 進行身份驗證（配合 reverse proxy）

### authorized_clients 說明

#### 用途

`authorized_clients` 控制**誰有資格呼叫 kube-federated-auth**。這是一個重要的安全機制。

#### 格式

```
{cluster}/{namespace}/{serviceaccount}
```

可使用 `*` 作為萬用字元。

#### 運作流程

```
sub-1-1 上的 my-app
    │
    │  想要驗證 sub-1-2 傳來的 token
    │
    │  POST /apis/authentication.k8s.io/v1/tokenreviews
    │  Header: Authorization: Bearer <my-app 自己的 SA token>   ← 這是「呼叫者身份」
    │  Body: { "spec": { "token": "<sub-1-2 傳來的 token>" } }  ← 這是「被驗證的 token」
    ▼
kube-federated-auth（在 sub-1-1）
    │
    │  Step 1: 驗證 Authorization header 裡的 token
    │          → 使用 JWKS 解析，得到 "sub-1-1/default/my-app"
    │          → 比對 authorized_clients 白名單
    │          → 在白名單中 → 放行 ✅（不在 → 403）
    │
    │  Step 2: 驗證 Body 裡的 token（被驗證的那個）
    │          → 使用 JWKS 偵測來自哪個 cluster
    │          → forward 至 sub-1-2 執行 TokenReview
    ▼
    回傳結果給 my-app
```

#### 兩個 token 的角色

| | Header Authorization Bearer | Body spec.token |
|---|---|---|
| **是什麼** | 呼叫者自己的 SA token | 要被驗證的 token |
| **用途** | 確認「誰在問」| 確認「被問的人是誰」|
| **對應** | authorized_clients 白名單 | clusters 設定 |

#### 範例

```yaml
authorized_clients:
  - "sub-1-2/*/*"   # sub-1-2 的任何 namespace、任何 SA 都可以呼叫
  - "sub-1-1/*/*"   # sub-1-1 自己的也可以
```

意思是：
- ✅ `sub-1-2` 的 `my-app` pod 帶著自己的 SA token 來呼叫 sub-1-1 的 KFA → 允許
- ❌ `sub-2-1` 的 pod 帶著自己的 SA token 來呼叫 sub-1-1 的 KFA → 403（不在白名單）

**這就是如何實現叢集間隔離的關鍵機制！**

## 網路架構

### 網路規劃

- **10.x 網段**: Central cluster → Sub clusters（單向通訊）
- **100.x 網段**: 同組 Sub clusters 之間互通（雙向通訊）

### 網路隔離

- sub-1-x 和 sub-2-x 之間**完全隔離**
- 隔離靠的是 **kube-federated-auth 的 cluster 白名單**
- sub-1-1 的 KFA 設定中沒有 `sub-2-*` → 即使 sub-2 的 token 傳過來，也會回應 `token not valid for any configured cluster`
- 不需要 NetworkPolicy，純設定層隔離

## 安裝指南

### 前置準備

1. Helm 3.x 已安裝
2. kubectl 可以存取各個 cluster
3. 每個 cluster 的 API server 可以透過對應網段存取

---

### 方式一：使用合併版 chart（推薦）

合併版將 `kube-federated-auth`、`aqsh`、Redis 全部整合在 **一個 Deployment** 中，一條指令即可完成安裝。

#### 1. 在所有 Sub Clusters 安裝（含 reader）

```bash
# 在 sub-1-1（啟用 reader，無 remote cluster）
helm install kfa-aqsh charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --set reader.enabled=true \
  --set kubeFederatedAuth.clusterName=sub-1-1

# 在 sub-1-2（啟用 reader）
helm install kfa-aqsh charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --set reader.enabled=true \
  --set kubeFederatedAuth.clusterName=sub-1-2
```

#### 2. 取得各 Sub Cluster 的憑證和 Token

```bash
# 取得 CA 憑證
kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}'

# 取得 ServiceAccount token（Kubernetes 1.24+）
kubectl create token kube-federated-auth-reader \
  --namespace kube-system \
  --duration=168h
```

#### 3. 在 Central Cluster 安裝（含所有 remote cluster 設定）

```bash
# 使用 examples/combined-central-values.yaml 作為範本
# 記得填入實際的 CA cert 和 bootstrap token
helm install kfa-aqsh charts/kube-federated-auth-aqsh \
  --namespace kube-system \
  --create-namespace \
  --values examples/combined-central-values.yaml
```

安裝後每個 cluster 會有：
- 1 個 Deployment（含 `kube-federated-auth` + `aqsh` 兩個 container）
- 1 個 Redis Deployment（獨立）
- 對應的 Services、ConfigMaps、RBAC

---

### 方式二：使用獨立版 charts（進階）

#### 1. 在所有 Sub Clusters 安裝 Reader

先在每個 sub cluster 建立 reader ServiceAccount 和 RBAC：

```bash
# 在 sub-1-1
helm install kfa-reader charts/kube-federated-auth-reader \
  --namespace kube-system \
  --create-namespace

# 在 sub-1-2
helm install kfa-reader charts/kube-federated-auth-reader \
  --namespace kube-system \
  --create-namespace

# 在 sub-2-1
helm install kfa-reader charts/kube-federated-auth-reader \
  --namespace kube-system \
  --create-namespace

# 在 sub-2-2
helm install kfa-reader charts/kube-federated-auth-reader \
  --namespace kube-system \
  --create-namespace
```

#### 2. 取得各 Sub Cluster 的憑證和 Token

每個 sub cluster 需要取得：

```bash
# 取得 CA 憑證
kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}'

# 取得 ServiceAccount token（Kubernetes 1.24+）
kubectl create token kube-federated-auth-reader \
  --namespace kube-system \
  --duration=168h
```

將這些資訊填入對應的 values 檔案。

#### 3. 安裝 Central Cluster 的 kube-federated-auth

```bash
# 使用 examples/central-values.yaml 作為範本
# 記得填入實際的 CA cert 和 bootstrap token
helm install kfa charts/kube-federated-auth \
  --namespace kube-system \
  --create-namespace \
  --values examples/central-values.yaml
```

#### 4. 安裝各 Sub Cluster 的 kube-federated-auth

```bash
# sub-1-1（只知道 sub-1-2）
helm install kfa charts/kube-federated-auth \
  --namespace kube-system \
  --values examples/sub-1-1-values.yaml

# sub-1-2（只知道 sub-1-1）
helm install kfa charts/kube-federated-auth \
  --namespace kube-system \
  --values examples/sub-1-2-values.yaml

# sub-2-1（只知道 sub-2-2）
helm install kfa charts/kube-federated-auth \
  --namespace kube-system \
  --values examples/sub-2-1-values.yaml

# sub-2-2（只知道 sub-2-1）
helm install kfa charts/kube-federated-auth \
  --namespace kube-system \
  --values examples/sub-2-2-values.yaml
```

#### 5. 在所有 Clusters 安裝 aqsh

```bash
# 在每個 cluster（central, sub-1-1, sub-1-2, sub-2-1, sub-2-2）
helm install aqsh charts/aqsh \
  --namespace aqsh \
  --create-namespace \
  --values examples/aqsh-values.yaml
```

### 安裝順序總結

| 步驟 | Central | sub-1-1 | sub-1-2 | sub-2-1 | sub-2-2 |
|------|:-------:|:-------:|:-------:|:-------:|:-------:|
| 1. 安裝 reader | - | ✅ | ✅ | ✅ | ✅ |
| 2. 取得憑證/token | - | ✅ | ✅ | ✅ | ✅ |
| 3. 安裝 KFA server | ✅ | - | - | - | - |
| 4. 安裝 KFA server | - | ✅ | ✅ | ✅ | ✅ |
| 5. 安裝 aqsh | ✅ | ✅ | ✅ | ✅ | ✅ |

## 設定檔說明

### kube-federated-auth Values

主要設定項目：

```yaml
# 叢集角色
clusterRole: central  # 或 sub-same-group

# 叢集名稱
clusterName: central

# 授權的呼叫者（白名單）
authorizedClients:
  - "central/*/*"
  - "sub-1-1/*/*"

# 遠端叢集設定
remoteClusters:
  - name: sub-1-1
    issuer: "https://sub-1-1.example.com:6443"
    apiServer: "https://10.1.1.1:6443"  # 或 100.x.x.x
    caCert: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
    bootstrapToken: "eyJhbGc..."
```

### aqsh Values

主要設定項目：

```yaml
aqsh:
  mode: both  # 或 api、worker

  # 身份驗證 header
  identityHeader: "X-Forwarded-User"
  groupsHeader: "X-Forwarded-Groups"
  requireIdentity: true

  # 任務定義
  tasksConfig: |
    tasks:
      - name: my-task
        script: /scripts/my-task.sh
        allowed_groups:
          - "system:authenticated"

  # Shell 腳本
  scripts:
    my-task.sh: |
      #!/bin/bash
      echo "Hello from $AQSH_SUBMITTER"
```

## 使用範例

### 驗證跨叢集身份

從 sub-1-1 驗證 sub-1-2 的 token：

```bash
# 在 sub-1-1 的 pod 中
TOKEN_TO_VERIFY="<sub-1-2 的 SA token>"

curl -k -X POST https://kfa-kube-federated-auth.kube-system:8443/apis/authentication.k8s.io/v1/tokenreviews \
  -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  -H "Content-Type: application/json" \
  -d "{
    \"apiVersion\": \"authentication.k8s.io/v1\",
    \"kind\": \"TokenReview\",
    \"spec\": {
      \"token\": \"$TOKEN_TO_VERIFY\"
    }
  }"
```

### 使用 aqsh 執行任務

```bash
# 提交任務
curl -X POST http://aqsh-aqsh.aqsh:8080/api/tasks/hello \
  -H "X-Forwarded-User: system:serviceaccount:default:my-app" \
  -H "Content-Type: application/json" \
  -d '{}'

# 查詢任務狀態
curl http://aqsh-aqsh.aqsh:8080/api/tasks/<task-id>

# 串流日誌
curl http://aqsh-aqsh.aqsh:8080/api/tasks/<task-id>/logs
```

## 常見問題

### Q1: 為什麼需要分別安裝 reader chart？

A: Reader chart 只建立 ServiceAccount 和 RBAC，非常輕量。它讓 central cluster 可以用這個 SA 的 token 去呼叫 sub cluster 的 TokenReview API，進行權威驗證。

### Q2: Token 會過期嗎？

A: 會。預設 7 天過期，但 kube-federated-auth 會在 48 小時前自動更新，無需人工介入。

### Q3: 如何確保 sub-1-x 和 sub-2-x 完全隔離？

A: 透過兩個機制：
1. **設定層隔離**：sub-1-x 的 `remoteClusters` 不配置 sub-2-x，`authorized_clients` 也不包含 sub-2-x
2. **JWKS 驗證**：即使有人嘗試傳 sub-2-x 的 token，kube-federated-auth 會回應「token not valid for any configured cluster」

### Q4: aqsh 如何與 kube-federated-auth 整合？

A: 在 aqsh 前面放一個 reverse proxy（如 nginx 或 kube-auth-proxy）：
1. Proxy 呼叫 kube-federated-auth 驗證 token
2. 驗證通過後，proxy 將 `X-Forwarded-User` 和 `X-Forwarded-Groups` header 加到 request
3. aqsh 讀取這些 header 進行授權檢查

### Q5: 可以只安裝 kube-federated-auth 不安裝 aqsh 嗎？

A: 可以！兩者是獨立的。kube-federated-auth 負責身份驗證，aqsh 負責任務執行。你可以只安裝其中一個。

## 授權

本專案基於上游專案：
- [rophy/kube-federated-auth](https://github.com/rophy/kube-federated-auth)
- [rophy/aqsh](https://github.com/rophy/aqsh)

## 貢獻

歡迎提交 Issue 和 Pull Request！

## 聯絡方式

如有問題，請在 GitHub Issues 中提出。
