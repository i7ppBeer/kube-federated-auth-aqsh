# kube-fedrunner

Primary English documentation.

`kube-fedrunner` is the repository for a Helm chart stack that composes these components:
- kube-federated-auth
- kube-auth-proxy (optional sidecar for aqsh)
- aqsh
- redis

The repository supports two deployment styles:
- install the main chart directly
- use the wrapper chart to manage config from files/

## Project Layout

- Main chart: `charts/kube-federated-auth-aqsh`
- Wrapper chart example: `examples/wrapper-chart`
- PR CI workflow: `.github/workflows/pr-helm-tests.yml`

## Core Components

| Component | Default Name | Purpose | Main Port |
|---|---|---|---|
| kube-federated-auth | `<release>-kube-federated-auth` | TokenReview backend | 8443 |
| aqsh | `<release>-aqsh` | Async job API/Worker | 8080 |
| kube-auth-proxy | aqsh sidecar | Bearer token validation proxy | 4180 |
| redis | `<release>-redis` | Queue and log stream backend | 6379 |

## Architecture Diagram

```text
External Client / CI / ServiceAccount Caller
  |
  | 1) HTTPS request + Authorization: Bearer <token>
  v
+----------------------------------------------------------------------------------+
| Kubernetes Namespace                                                             |
|                                                                                  |
|  +----------------------------------- Service --------------------------------+  |
|  | <release>-aqsh Service                                                 :4180|  |
|  +---------------------------------------------------------------------------+  |
|                                      |                                          |
|                                      v                                          |
|    +--------------------------- Deployment: <release>-aqsh ------------------+   |
|    |                                                                         |   |
|    |  +--------------------------+      2) validate token                    |   |
|    |  | kube-auth-proxy          | -----------------------------------+      |   |
|    |  | containerPort: 4180      |                                    |      |   |
|    |  |                          | <- 3) TokenReview response --------+      |   |
|    |  | on success injects:      |                                           |   |
|    |  | - X-Forwarded-User       | 4) forward request (auth headers)         |   |
|    |  | - X-Forwarded-Groups     | ------------------------------+            |   |
|    |  +--------------------------+                              |            |   |
|    |                                                            v            |   |
|    |  +--------------------------+      5) enqueue job         +----------+  |   |
|    |  | aqsh API/Worker          | --------------------------> |  Redis   |  |   |
|    |  | containerPort: 8080      | <-------------------------- |  :6379   |  |   |
|    |  |                          | 6) consume queue / logs     +----------+  |   |
|    |  +--------------------------+                                           |   |
|    +-------------------------------------------------------------------------+   |
|                                      |                                          |
|                                      | 2) TokenReview request                   |
|                                      v                                          |
|  +---------------------------- Service --------------------------------------+  |
|  | <release>-kube-federated-auth Service                                :8443|  |
|  +---------------------------------------------------------------------------+  |
|                                      |                                          |
|                                      v                                          |
|                    +------------------------------------------+                  |
|                    | kube-federated-auth Deployment          |                  |
|                    | - verifies SA token                     |                  |
|                    | - enforces authorized clients           |                  |
|                    +------------------------------------------+                  |
+----------------------------------------------------------------------------------+

7) Client polls task status / streams logs from aqsh endpoint.
```

Flow summary:
- Client calls aqsh through kube-auth-proxy.
- kube-auth-proxy validates tokens via kube-federated-auth.
- Validated identity headers are forwarded to aqsh.
- aqsh reads/writes queue and logs through Redis.

## Deployment Modes

### 1) Main chart directly

Use this when values.yaml-based configuration is sufficient.

```bash
helm install my-release charts/kube-federated-auth-aqsh -n my-namespace --create-namespace
```

### 2) Wrapper chart (recommended for team workflows)

Use this when you want tasks/clusters/scripts as file-managed assets.

```bash
helm dependency build examples/wrapper-chart
helm install my-release examples/wrapper-chart -n my-namespace --create-namespace
```

Wrapper-generated ConfigMap sources:
- `examples/wrapper-chart/files/clusters.yaml`
- `examples/wrapper-chart/files/tasks.yaml`
- `examples/wrapper-chart/files/scripts/*`
- `examples/wrapper-chart/files/ca-certs/*.crt`

## Important Values

### kubeFederatedAuth

- `enabled`: enable/disable kube-federated-auth
- `configMap.create`: create `kfa-config` from subchart
- `rbac.createClusterRole`: create ClusterRole/ClusterRoleBinding
- `remoteClusters`: remote cluster definitions
- `caCertsConfigMap.enabled`: mount externally supplied `<release>-kfa-ca-certs`
- `tokens.secretName` / `tokens.items`: custom token secret mount settings

### aqsh

- `enabled`: enable/disable aqsh
- `configMap.create`: create `aqsh-config` from subchart
- `redisAddr`: external Redis address (defaults to `<release>-redis`)
- `tasks`: task definitions
- `scripts`: inline scripts
- `scriptsConfigMap.enabled`: mount externally supplied `<release>-aqsh-scripts`

### kubeAuthProxy

- `enabled`: enable/disable sidecar
- `tokenReviewUrl`: token review endpoint (empty means auto-resolve to local release)
- `port`: proxy listen port (default 4180)

### redis

- `enabled`: enable/disable redis
- `persistence.enabled`: enable PVC
- `persistence.size` / `persistence.storageClass`: storage settings

## Wrapper Coordination Rules

When using the wrapper chart, keep these disabled to avoid duplicate ConfigMaps:
- `kube-federated-auth-aqsh.kubeFederatedAuth.configMap.create=false`
- `kube-federated-auth-aqsh.aqsh.configMap.create=false`

If scripts are supplied by wrapper-managed ConfigMap, also set:
- `kube-federated-auth-aqsh.aqsh.scriptsConfigMap.enabled=true`

## Testing and CI

### Local Commands

```bash
# wrapper dependency
helm dependency build examples/wrapper-chart

# lint
helm lint charts/kube-federated-auth-aqsh --strict
helm lint examples/wrapper-chart --strict

# unit tests (helm-unittest)
helm unittest charts/kube-federated-auth-aqsh
helm unittest examples/wrapper-chart
```

### PR Automation

`.github/workflows/pr-helm-tests.yml` runs on pull request events and includes:
1. helm setup
2. helm-unittest plugin install
3. wrapper dependency build
4. lint (main + wrapper)
5. unittest (main + wrapper)
6. smoke render

Set `PR Helm Tests / helm-tests` as a required branch protection check.

## Troubleshooting

### Q1: Wrapper dependency step fails in CI

Verify `examples/wrapper-chart/Chart.yaml` dependency source is resolvable and aligned with your lock/package state.

### Q2: aqsh cannot reach Redis

If `redis.enabled=false`, set `aqsh.redisAddr` to an external `host:port`.

### Q3: Why does service port change to 4180 when proxy is enabled?

Because service traffic goes through kube-auth-proxy; aqsh upstream remains on 8080.

## References

- kube-federated-auth: https://github.com/null-ptr-exception/kube-federated-auth
- kube-auth-proxy: https://github.com/null-ptr-exception/kube-auth-proxy
- aqsh: https://github.com/null-ptr-exception/aqsh
