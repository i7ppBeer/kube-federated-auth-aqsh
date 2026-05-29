# wrapper-chart example

示範如何將 `kube-federated-auth-aqsh` 作為 **Helm dependency (subchart)** 使用，
並透過本地 `files/` 目錄管理所有 ConfigMap 內容。

## 架構

```
my-aqsh-deployment/          ← 你的 wrapper chart
├── Chart.yaml               ← dependency: kube-federated-auth-aqsh
├── values.yaml              ← subchart 設定（含 configMap.create: false + scriptsConfigMap.enabled）
├── files/
│   ├── tasks.yaml           ← aqsh task 定義（純 YAML，非 template）
│   ├── clusters.yaml        ← kfa clusters 設定（純 YAML）
│   ├── ca-certs/            ← kfa CA 憑證（可選）
│   │   └── sub-1-1-ca.crt
│   └── scripts/
│       ├── deploy.sh        ← 部署 script
│       └── rollback.sh      ← 回滾 script
└── templates/
    └── configmap.yaml       ← 用 .Files.Get 讀取 files/ → 生成 ConfigMap
```

## 與直接使用 subchart 的差別

| | 直接使用 subchart | Wrapper chart |
|---|---|---|
| ConfigMap 來源 | `values.yaml` 內嵌 | `files/` 本地檔案 |
| tasks.yaml 編輯 | 需要 YAML 縮排 inside values | 直接編輯純 YAML 檔 |
| scripts 管理 | `values.yaml` 多行字串 | 獨立 `.sh` 檔案，可有 syntax highlight |
| 版本控制 | values.yaml 混雜設定與內容 | 設定與內容分離 |

## 資料流

```
files/tasks.yaml
      │ .Files.Get
      ▼
templates/configmap.yaml  →  ConfigMap: <release>-aqsh-config

files/clusters.yaml
      │ .Files.Get
      ▼
templates/configmap.yaml  →  ConfigMap: <release>-kfa-config

files/scripts/*.sh
      │ .Files.Glob
      ▼
templates/configmap.yaml  →  ConfigMap: <release>-aqsh-scripts

files/ca-certs/*.crt
  │ .Files.Glob
  ▼
templates/configmap.yaml  →  ConfigMap: <release>-kfa-ca-certs
```

## 使用方式

```bash
# 下載 subchart dependency
helm dependency update .

# 安裝
helm install my-release . -n my-namespace --create-namespace

# 升級
helm upgrade my-release . -n my-namespace
```

## 關鍵設定

`values.yaml` 中透過 `configMap.create: false` 停用 subchart 自動產生的 ConfigMap，
並啟用 `scriptsConfigMap.enabled` 讓 subchart 仍會 mount `<release>-aqsh-scripts`：

```yaml
kube-federated-auth-aqsh:
  kubeFederatedAuth:
    configMap:
      create: false   # ← 由本 wrapper chart 的 templates/ 接管
  aqsh:
    configMap:
      create: false   # ← 由本 wrapper chart 的 templates/ 接管
    scriptsConfigMap:
      enabled: true   # ← 仍掛載 <release>-aqsh-scripts

  # 可選：若 wrapper 提供 files/ca-certs/*.crt 並生成 <release>-kfa-ca-certs
  # 再啟用此開關讓 subchart mount CA 憑證
  # kubeFederatedAuth:
  #   caCertsConfigMap:
  #     enabled: true
```
