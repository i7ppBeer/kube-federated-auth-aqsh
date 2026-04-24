# kube-federated-auth-aqsh

A Helm chart that integrates three components into a single deployment for **cross-cluster authenticated async task execution** on Kubernetes.

## Components

| Component | Role | Port |
|---|---|---|
| **kube-federated-auth** | Cross-cluster SA token validation backend (TokenReview API) | 8443 |
| **kube-auth-proxy** | Reverse proxy sidecar — validates Bearer tokens, injects `X-Forwarded-*` headers | 4180 (optional) |
| **aqsh** | Async shell script task queue (HTTP API + Worker) | 8080 |
| **Redis** | Task queue and log stream storage (separate Deployment) | 6379 |

## How It Works

A service in **Cluster B** wants to trigger a task on **Cluster A**:

1. It sends a request with its own SA token: `Authorization: Bearer <token>`
2. **kube-auth-proxy** intercepts and calls kube-federated-auth to validate the token
3. **kube-federated-auth** identifies the source cluster via JWKS (locally, no token forwarding), then calls the original cluster's TokenReview API for authoritative validation
4. On success, kube-auth-proxy strips the Authorization header and injects `X-Forwarded-User`, `X-Forwarded-Groups`, `X-Forwarded-Extra-Cluster-Name`
5. **aqsh** checks `allowed_groups` per task, enqueues the job to Redis, and returns a task ID
6. The aqsh Worker picks up the job, runs the shell script with input as environment variables, and streams logs via SSE

## Access Control

Two independent layers:
- **`authorizedClients`** (kube-federated-auth): which ServiceAccounts may call the TokenReview API — format `{cluster}/{namespace}/{serviceaccount}`
- **`allowed_groups`** (aqsh, per-task): which Kubernetes groups may trigger a specific task — matched against `X-Forwarded-Groups`

## Key Design Decisions

- Token source cluster is identified **locally** using JWKS public keys — the token never leaves before cluster identity is known
- Remote cluster tokens are **auto-renewed** (7-day TTL, renewed 48h before expiry, stored in K8s Secret)
- Cluster isolation is **config-only** — no NetworkPolicy required; simply omit a cluster from `remoteClusters` and `authorizedClients`
- aqsh scripts can call any sidecar API via `localhost` and optionally write structured JSON to `$AQSH_RESULT_FILE`

---

## Architecture

### Cluster Topology

```mermaid
graph TD
    subgraph central["Central Cluster"]
        C_POD["Pod\nkube-auth-proxy :4180\nkube-federated-auth :8443\naqsh :8080"]
        C_REDIS["Redis"]
    end

    subgraph group1["Group 1"]
        subgraph sub11["sub-1-1"]
            S11_POD["Pod (same stack)"]
        end
        subgraph sub12["sub-1-2"]
            S12_POD["Pod (same stack)"]
        end
    end

    subgraph group2["Group 2"]
        subgraph sub21["sub-2-1"]
            S21_POD["Pod (same stack)"]
        end
        subgraph sub22["sub-2-2"]
            S22_POD["Pod (same stack)"]
        end
    end

    central -->|"10.x (one-way)"| sub11
    central -->|"10.x (one-way)"| sub12
    central -->|"10.x (one-way)"| sub21
    central -->|"10.x (one-way)"| sub22

    sub11 <-->|"100.x (mutual)"| sub12
    sub21 <-->|"100.x (mutual)"| sub22

    sub11 -. "✗ isolated" .- sub21
```

---

### Request Flow (E2E)

```mermaid
sequenceDiagram
    participant Client as Client<br/>(sub-1-2 / my-app)
    participant Proxy as kube-auth-proxy<br/>:4180
    participant KFA as kube-federated-auth<br/>:8443
    participant AQSH as aqsh<br/>:8080
    participant Worker as aqsh Worker
    participant Remote as sub-1-2<br/>API Server

    Client->>Proxy: POST /tasks/deploy<br/>Authorization: Bearer <token>

    Proxy->>KFA: POST /tokenreviews<br/>Bearer <proxy's own SA token><br/>body: { token: <client token> }

    KFA->>KFA: JWKS verify locally<br/>→ identifies token from sub-1-2
    KFA->>Remote: TokenReview (authoritative)
    Remote-->>KFA: authenticated ✅<br/>username / groups / cluster-name

    KFA-->>Proxy: user info

    Proxy->>AQSH: POST /tasks/deploy<br/>X-Forwarded-User: system:serviceaccount:default:my-app<br/>X-Forwarded-Groups: system:serviceaccounts:default,...<br/>X-Forwarded-Extra-Cluster-Name: sub-1-2

    AQSH->>AQSH: check allowed_groups ✅<br/>enqueue to Redis
    AQSH-->>Client: { id: "task_01HXXX", status: "pending" }

    Worker->>Worker: exec deploy.sh<br/>env: VERSION, ENVIRONMENT, AQSH_SUBMITTER
    Client->>AQSH: GET /tasks/task_01HXXX/logs (SSE)
```

---

### Pod Internal Components

```mermaid
flowchart LR
    EXT["External\nBearer token"] --> KAP

    subgraph pod["Pod"]
        KAP["kube-auth-proxy\n:4180\n─────────────\n1. validate token\n2. strip Authorization\n3. inject X-Forwarded-*"]
        KFA["kube-federated-auth\n:8443\n─────────────\nJWKS + TokenReview\nauthorizedClients check"]
        AQSH["aqsh\n:8080\n─────────────\nallowed_groups check\nRedis enqueue\nscript exec"]

        KAP -->|"POST /tokenreviews\nlocalhost:8443"| KFA
        KAP -->|"X-Forwarded-*\nlocalhost:8080"| AQSH
    end

    subgraph redis_pod["Redis (separate Deployment)"]
        REDIS["Redis :6379\nAsynq queue\nLog streams"]
    end

    AQSH <--> REDIS
```
