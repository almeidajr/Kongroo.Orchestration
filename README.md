# <img alt="Kongroo" src="./logo.png" width="40"/> Kongroo.Orchestration

Central guide and infrastructure repository for **FIAP Cloud Games Phase 3** (Kongroo). Application
code lives in the sibling service repositories; this repo holds Docker Compose, the Kubernetes manifests
(Kustomize), the API gateway configuration, the monitoring stack and the scripts that tie them together.

## Repositories

| Repository | Role | Link |
| --- | --- | --- |
| Kongroo.Identity | Users, authentication, JWT issuance (UsersAPI) | https://github.com/almeidajr/Kongroo.Identity |
| Kongroo.Catalog | Games, promotions, orders, library, **reviews (MongoDB)**, **cache (Redis)** (CatalogAPI) | https://github.com/almeidajr/Kongroo.Catalog |
| Kongroo.Payments | Payment simulation (PaymentsAPI) | https://github.com/almeidajr/Kongroo.Payments |
| Kongroo.Notifications | **AWS Lambda** triggered by SQS (serverless NotificationsAPI) + SAM template | https://github.com/almeidajr/Kongroo.Notifications |
| Kongroo.Orchestration | This repo: compose, k8s, Kong, Prometheus/Grafana, scripts, docs | https://github.com/almeidajr/Kongroo.Orchestration |

Architecture reference: [ARCHITECTURE.md](./ARCHITECTURE.md).

## Prerequisites

- **Docker**: Rancher Desktop on this project's machine (with Kubernetes enabled for the k8s path).
- **kubectl**: for the Kubernetes bring-up.
- **PowerShell 7**: every script is `#requires -Version 7`.
- **.NET 10 SDK**: only needed to build the service images from source.
- **Kubernetes path only**: an AWS Academy Learner Lab account, the AWS CLI, and the AWS SAM CLI with
  `Amazon.Lambda.Tools`.
- Pushing images to Docker Hub needs `docker login` first.

## Phase 3 stack: the choices

| Requirement | Choice | Where |
| --- | --- | --- |
| API Gateway | **Kong Gateway 3.9 (OSS), DB-less**, `jwt` plugin (HS256, issuer `Kongroo.Identity.Api`), `prometheus` plugin | `k8s/kong/kong.yaml` (shared by compose and k8s) |
| Serverless | **AWS Lambda (.NET 10)** triggered by **SQS**, subscribed to the MassTransit **SNS** topics; **SAM** IaC; AWS Academy Learner Lab | Kongroo.Notifications `template.yaml` |
| Messaging | MassTransit with a config switch: **RabbitMQ** for compose and tests, **Amazon SQS/SNS** on k8s (`Messaging__Transport`) | service ConfigMaps |
| Observability | **Option A: Prometheus + Grafana** as k8s manifests; OpenTelemetry `/metrics` on Identity, Catalog, Payments; Kong metrics | `k8s/prometheus`, `k8s/grafana` |
| NoSQL | **MongoDB 8** for Catalog game reviews via `MongoDB.Driver` | `k8s/mongodb`, Catalog `POST/GET /games/{id}/reviews` |
| Cache | **Redis 8**: Catalog `HybridCache` over `IDistributedCache` (StackExchange provider) for game reads, tag invalidation on writes | `k8s/redis` |

## Two ways to run

Docker Compose and Kubernetes share the host ports (8000, 3000, 9090 among others), so run only one mode
at a time.

| Mode | What runs | Notifications |
| --- | --- | --- |
| **Docker Compose** (`docker compose up --build`) | Kong, 3 APIs, Postgres, RabbitMQ, MongoDB, Redis, Elasticsearch, Prometheus, Grafana | not fired (broker is RabbitMQ, the Lambda lives in AWS) |
| **Kubernetes + Learner Lab** (`kubectl apply -k k8s/`) | same, with the APIs on Amazon SQS | Lambda logs in CloudWatch |

Required sibling layout (compose build contexts are relative):

```
repos/
  Kongroo.Identity/
  Kongroo.Catalog/
  Kongroo.Payments/
  Kongroo.Notifications/
  Kongroo.Orchestration/   ← this repo
```

## Endpoints and ports

| Component | Compose | Kubernetes | Notes |
| --- | --- | --- | --- |
| **Kong proxy (single entry point)** | http://localhost:8000 | http://localhost:8000 (LoadBalancer 8000; Traefik owns 80 on Rancher Desktop) | `/identity/**`, `/catalog/**`, `/payments/**` |
| Kong status + metrics | http://localhost:8100/metrics | in-cluster `kong-status:8100` | scraped by Prometheus |
| Grafana | http://localhost:3000/d/kongroo | http://localhost:3000/d/kongroo | anonymous Viewer; `admin` / `GRAFANA_ADMIN_PASSWORD` from `.env` |
| Prometheus | http://localhost:9090 | `kubectl -n kongroo port-forward svc/prometheus 9090` | targets: identity-api, catalog-api, payments-api, kong |
| RabbitMQ UI | http://localhost:15672 | `port-forward svc/rabbitmq 15672` | `kongroo` / `RABBITMQ_PASSWORD` from `.env` |
| identity-api / catalog-api / payments-api | 5101 / 5102 / 5103 (direct, dev only) | ClusterIP 8080 only; go through Kong | |
| postgres / mongodb / redis | 5432 / 27017 / 6379 | ClusterIP | |
| elasticsearch | http://localhost:9200 | ClusterIP 9200 | `elastic` / `ELASTIC_PASSWORD` from `.env`; plain HTTP, `elasticsearch:9.5.5` |

### Gateway routes

| Public path | Upstream | JWT verified at Kong |
| --- | --- | --- |
| `POST /identity/users`, `POST /identity/tokens` | identity-api | no (register, login) |
| `/identity/**` (everything else) | identity-api | yes |
| `/catalog/**` | catalog-api | yes |
| `/payments/**` | payments-api | yes |

Kong validates the HS256 signature and `exp` against the shared signing key `JWT_SIGNING_KEY`, then
forwards the `Authorization` header so each service still validates the token itself. The committed
`k8s/kong/kong.yaml` holds only the placeholder `__JWT_SIGNING_KEY__`; Kong's start command substitutes
the key from its environment (`.env` in compose, `kong-secret` in Kubernetes, where the file is a
`configMapGenerator`) into a temporary copy and starts from that.

## Bring-up: Docker Compose (fresh clone)

```powershell
foreach ($repo in "Identity", "Catalog", "Payments", "Notifications", "Orchestration") {
    git clone "https://github.com/almeidajr/Kongroo.$repo"
}
cd Kongroo.Orchestration
./scripts/new-secrets.ps1 -SkipKubernetes   # every local credential, see Secrets below
docker compose up --build -d
./scripts/demo.ps1                          # register → login → publish game → buy → review, all via Kong
```

For Kubernetes, clone the same way and follow the next section instead of `docker compose up`.
`-SkipKubernetes` leaves the cluster alone; `-SkipUserSecrets` skips the APIs' user-secrets on a machine
without the .NET SDK. Compose reads `.env` on its own and stops with "run scripts/new-secrets.ps1" when
it is missing. `init-db.sql` creates the three PostgreSQL databases on the first start
(`docker compose down -v` to reset).

Volumes created before `new-secrets.ps1` existed hold the old committed passwords, and the APIs fail
to authenticate against them. Delete them once: `docker compose down -v`, and
`kubectl delete namespace kongroo` for k3s, then run `new-secrets.ps1` again. The same applies whenever `.env` is deleted.

## Bring-up: Kubernetes + AWS Academy Learner Lab

1. **Start the lab** and paste **AWS Details → AWS CLI** into `~/.aws/credentials` (`[default]` profile).
2. **Deploy the Lambda once** (from `../Kongroo.Notifications`): `sam build && sam deploy`. Redeploy only when the function changes.
3. **Deploy the cluster**: `./scripts/new-secrets.ps1` (creates the namespace and every Secret; safe to
   rerun), then `kubectl apply -k k8s/`
4. **Load the session credentials** into the cluster. **Run this after every `kubectl apply -k k8s/`** (the apply resets the Secret to placeholders) **and after every new lab session**:
   `./scripts/set-aws-credentials.ps1` writes the `aws-credentials` Secret and restarts the three APIs.
   The `masstransit-bus` health check is in the `ready` set, so stale credentials keep the API pods out of
   Kong and Prometheus until this script runs; a loud failure beats a pod that serves with a dead bus.
5. **Check**: `kubectl -n kongroo get pods` (all `1/1 Running`), then
   `./scripts/demo.ps1 -AdminUsername admin`

   On a cold cluster the three API pods restart exactly once: they start before Postgres accepts
   connections, the startup migration fails and the host stops; Kubernetes restarts them and they come
   up clean. That single restart is expected, not a fault.
6. **Watch the Lambda**: `sam logs --stack-name kongroo-notifications --name NotificationsFunction --tail`

Images are pulled from the pinned `josealmeidajr/kongroo-<service>:0.1.0` tags (`k8s/kustomization.yaml`).
To publish new images: build in each service repo, `docker push`, bump the tag, run `./sync.ps1`.

### SNS/SQS topology

The CloudFormation stack `kongroo-notifications` (`us-east-1`, role `LabRole`) creates the SNS topics
`kongroo-user-created` and `kongroo-payment-processed`, the SQS queue `kongroo-notifications` and its
dead-letter queue `kongroo-notifications-dlq` (3 receives → DLQ). The services create the rest of the
topology themselves at bus start: topic `kongroo-order-placed` and the consumer queues
`catalog-payment-processed-integration-event` and `payments-order-placed-integration-event`. The topic
`kongroo-user-role-changed` only appears once a role change is actually published, because MassTransit
creates publish topics lazily, so its absence on a fresh stack is expected, not a failure.

### Kubernetes layout

```
k8s/
  kustomization.yaml            namespace, resources, images, configMapGenerators
  namespace.yaml
  aws-credentials.secret.yaml   placeholders, refreshed by scripts/set-aws-credentials.ps1
  kong/                         kong.yaml (declarative, key placeholder, from a configMapGenerator), deployment, LoadBalancer service, status service
  prometheus/                   prometheus.yml (static targets), deployment, service
  grafana/                      provisioning (datasource, dashboard provider), dashboards/kongroo.json, deployment, service
  postgres/  rabbitmq/  mongodb/  redis/  elasticsearch/
                                no Secret manifests: scripts/new-secrets.ps1 creates them
  identity/  catalog/  payments/   ← generated by sync.ps1 from the service repos; do not edit
```

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/new-secrets.ps1` | Generates every local credential into `.env` (only if absent), sets the APIs' user-secrets and creates the Kubernetes Secrets; idempotent |
| `scripts/check.ps1` | No `secret.yaml` anywhere, `kong config parse`, `kubectl kustomize`, `docker compose config`, `cfn-lint` on `eks/*-stack.yaml` (needs `cfn-lint` on PATH, e.g. `uv tool install cfn-lint`), `sync.ps1 -Check` |
| `scripts/demo.ps1` | Drives every graded flow through Kong (compose defaults; `./scripts/demo.ps1 -AdminUsername admin` for k8s) |
| `scripts/set-aws-credentials.ps1` | Copies Learner Lab credentials into the cluster and restarts the APIs |
| `sync.ps1` | Regenerates `k8s/<service>/` from the sibling repos (`-Check` detects drift) |

## Observability (Option A)

- Identity, Catalog and Payments expose `/metrics` (OpenTelemetry → Prometheus exporter): ASP.NET Core
  request duration by route and status code, HttpClient, .NET runtime, MassTransit publish/consume.
- Kong exposes edge metrics per service/route on its status port.
- Prometheus scrapes four static targets every 15 s (`k8s/prometheus/prometheus.yml`), all UP:
  `identity-api`, `catalog-api`, `payments-api`, `kong`.
- Grafana provisions the **Kongroo** dashboard (uid `kongroo`): requests/s, error rate, p50/p95 latency,
  requests by status code, Kong requests and latency, MassTransit message rates
  (`messaging_masstransit_send_ea_total` / `messaging_masstransit_consume_ea_total`, where the OpenTelemetry
  Prometheus exporter appends the instrument unit, so a publish through the EF outbox is exported as a
  send).
- Lambda logs are in CloudWatch (`sam logs`), the centralized platform for the serverless piece.

## Secrets

No password, key, token or connection string is committed. Locally, `scripts/new-secrets.ps1` generates
random values into the git-ignored `.env` once and reuses them on every rerun; from that file it creates
the Kubernetes Secrets in the current context and sets the APIs' user-secrets (hosts rewritten to
`localhost`). The EKS deployment is planned, not built yet: `eks/up.ps1`, `eks/arm.ps1` and the EKS
overlay do not exist. Once they do, each cloud day `eks/up.ps1` will run the same script against EKS
with a fresh git-ignored `eks/.env`, so cloud and local never share a value. Usernames, hostnames,
issuer and audience are configuration, not secrets.

| Credential | Local source | Cloud source (EKS, planned) | How it is injected |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose `${POSTGRES_PASSWORD}`; Secret `postgres-secret` |
| `RABBITMQ_PASSWORD` | `.env` | `eks/.env` (unused: EKS runs on SQS, the overlay will drop RabbitMQ) | compose; Secret `rabbitmq-secret`; `RabbitMq__Pass` in each API's Secret and user-secrets |
| `MONGO_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose; Secret `mongodb-secret` |
| `GRAFANA_ADMIN_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose; Secret `grafana-secret` |
| `ELASTIC_PASSWORD` | `.env` | `eks/.env` (unused: the overlay will drop the local Elasticsearch, Catalog will use Elastic Cloud) | compose; Secret `elasticsearch-secret`; Catalog `Search__Password` in `catalog-secret` and user-secrets |
| `JWT_SIGNING_KEY` (hex) | `.env` | `eks/.env`, new each cloud day | `Jwt__SigningKey` in `identity-secret`, `catalog-secret`, `payments-secret` and user-secrets; Kong reads it from `kong-secret` (compose: `.env`) and substitutes it into `kong.yaml` at start |
| `BOOTSTRAP_ADMIN_PASSWORD` | `.env` | `eks/.env`, new each cloud day | `BootstrapAdmin__Password` in `identity-secret` and user-secrets; `demo.ps1` reads it from `.env` |
| `IDENTITY_DATABASE_CONNECTION_STRING`, `CATALOG_DATABASE_CONNECTION_STRING`, `PAYMENTS_DATABASE_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | `ConnectionStrings__Database` in each API's Secret and user-secrets |
| `MONGO_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | Catalog `Mongo__ConnectionString` in `catalog-secret` and user-secrets |
| `REDIS_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | Catalog `ConnectionStrings__Redis` in `catalog-secret` and user-secrets |
| Elastic Cloud user (`kongroo-catalog`) | none: local search uses the `elastic` user above | `SEARCH_URI` / `SEARCH_USERNAME` / `SEARCH_PASSWORD` in the hand-filled, git-ignored `eks/cloud.env`; `eks/up.ps1` will stop without it | `Search__Uri`, `Search__Username`, `Search__Password` in `catalog-secret`, which overrides `catalog-config` |
| AWS | Learner Lab session keys pasted into `~/.aws/credentials` | none in the cluster: pods will use the node's `LabRole` through IMDS; CI will get the session keys as repository secrets from `eks/arm.ps1` | k3s: `scripts/set-aws-credentials.ps1` fills the `aws-credentials` Secret (committed with placeholders only); AWS SDK default credential chain |

Known trade-off: `new-secrets.ps1` passes values to `kubectl create secret --from-literal`, so they are
briefly visible on the local machine's process list while the script runs.
