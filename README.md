# <img alt="Kongroo" src="./logo.png" width="40"/> Kongroo.Orchestration

Central guide and infrastructure repository for **FIAP Cloud Games — Phase 3** (Kongroo). Application
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

## Phase 3 stack — the choices

| Requirement | Choice | Where |
| --- | --- | --- |
| API Gateway | **Kong Gateway 3.9 (OSS), DB-less**, `jwt` plugin (HS256, issuer `Kongroo.Identity.Api`), `prometheus` plugin | `k8s/kong/kong.yaml` (shared by compose and k8s) |
| Serverless | **AWS Lambda (.NET 10)** triggered by **SQS**, subscribed to the MassTransit **SNS** topics; **SAM** IaC; AWS Academy Learner Lab | Kongroo.Notifications `template.yaml` |
| Messaging | MassTransit with a config switch: **RabbitMQ** for compose and tests, **Amazon SQS/SNS** on k8s (`Messaging__Transport`) | service ConfigMaps |
| Observability | **Option A — Prometheus + Grafana** as k8s manifests; OpenTelemetry `/metrics` on Identity, Catalog, Payments; Kong metrics | `k8s/prometheus`, `k8s/grafana` |
| NoSQL | **MongoDB 8** — Catalog game reviews via `MongoDB.Driver` | `k8s/mongodb`, Catalog `POST/GET /games/{id}/reviews` |
| Cache | **Redis 8** — Catalog `HybridCache` over `IDistributedCache` (StackExchange provider) for game reads, tag invalidation on writes | `k8s/redis` |

## Two ways to run

| Mode | What runs | Notifications |
| --- | --- | --- |
| **Docker Compose** (`docker compose up --build`) | Kong, 3 APIs, Postgres, RabbitMQ, MongoDB, Redis, Prometheus, Grafana | not fired (broker is RabbitMQ, the Lambda lives in AWS) |
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
| Grafana | http://localhost:3000/d/kongroo | http://localhost:3000/d/kongroo | anonymous Viewer; `admin` / `development` |
| Prometheus | http://localhost:9090 | `kubectl -n kongroo port-forward svc/prometheus 9090` | targets: identity-api, catalog-api, payments-api, kong |
| RabbitMQ UI | http://localhost:15672 | `port-forward svc/rabbitmq 15672` | `kongroo` / `development` |
| identity-api / catalog-api / payments-api | 5101 / 5102 / 5103 (direct, dev only) | ClusterIP 8080 only — go through Kong | |
| postgres / mongodb / redis | 5432 / 27017 / 6379 | ClusterIP | |

### Gateway routes

| Public path | Upstream | JWT verified at Kong |
| --- | --- | --- |
| `POST /identity/users`, `POST /identity/tokens` | identity-api | no (register, login) |
| `/identity/**` (everything else) | identity-api | yes |
| `/catalog/**` | catalog-api | yes |
| `/payments/**` | payments-api | yes |

Kong validates the HS256 signature and `exp` against the shared development signing key (inline in
`k8s/kong/kong.yaml`, which Kubernetes mounts from a Secret), then forwards the `Authorization` header so
each service still validates the token itself.

## Bring-up: Docker Compose

```powershell
docker compose up --build -d
./scripts/demo.ps1                     # register → login → publish game → buy → review, all via Kong
```
`init-db.sql` creates the three PostgreSQL databases on the first start (`docker compose down -v` to reset).

## Bring-up: Kubernetes + AWS Academy Learner Lab

1. **Start the lab** and paste **AWS Details → AWS CLI** into `~/.aws/credentials` (`[default]` profile).
2. **Deploy the Lambda once** (from `../Kongroo.Notifications`): `sam build && sam deploy`. Redeploy only when the function changes.
3. **Deploy the cluster**: `kubectl apply -k k8s/`
4. **Load the session credentials** into the cluster — **run this after every `kubectl apply -k k8s/`** (the apply resets the Secret to placeholders) **and after every new lab session**:
   `./scripts/set-aws-credentials.ps1` — writes the `aws-credentials` Secret and restarts the three APIs.
   The `masstransit-bus` health check is in the `ready` set, so stale credentials keep the API pods out of
   Kong and Prometheus until this script runs — a loud failure beats a pod that serves with a dead bus.
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
`kongroo-user-role-changed` only appears once a role change is actually published — MassTransit creates
publish topics lazily, so its absence on a fresh stack is expected, not a failure.

### Kubernetes layout

```
k8s/
  kustomization.yaml            namespace, resources, images, configMapGenerators
  namespace.yaml
  aws-credentials.secret.yaml   placeholders — refreshed by scripts/set-aws-credentials.ps1
  kong/                         kong.yaml (declarative, mounted from a generated Secret), deployment, LoadBalancer service, status service
  prometheus/                   prometheus.yml (static targets), deployment, service
  grafana/                      provisioning (datasource, dashboard provider), dashboards/kongroo.json, deployment, service, secret
  postgres/  rabbitmq/  mongodb/  redis/
  identity/  catalog/  payments/   ← generated by sync.ps1 from the service repos; do not edit
```

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/check.ps1` | `kong config parse`, `kubectl kustomize`, `sync.ps1 -Check` |
| `scripts/demo.ps1` | Drives every graded flow through Kong (compose defaults; `-Gateway http://localhost -AdminUsername admin` for k8s) |
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
  (`messaging_masstransit_send_ea_total` / `messaging_masstransit_consume_ea_total` — the OpenTelemetry
  Prometheus exporter appends the instrument unit, so a publish through the EF outbox is exported as a
  send).
- Lambda logs are in CloudWatch (`sam logs`), the centralized platform for the serverless piece.

## Credentials (development values, committed on purpose)

| Where | Value |
| --- | --- |
| Postgres / RabbitMQ / MongoDB | `kongroo` / `development` |
| JWT signing key | `Development.SigningKey.AtLeast32Characters!` (identity, catalog, kong secrets must match) |
| Bootstrap admin | compose `developer` / `Sup3rSecure!`; k8s `admin` / `Sup3rSecure!` |
| Grafana admin | `admin` / `development` |
| AWS | never committed — Learner Lab session values via `scripts/set-aws-credentials.ps1` |
