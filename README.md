# <img alt="Kongroo" src="./logo.png" width="40"/> Kongroo.Orchestration

Central guide and infrastructure repository for **FIAP Cloud Games Phase 4** (Kongroo). Application code lives in the sibling
service repositories; this repo holds Docker Compose, the Kubernetes manifests (Kustomize), the EKS overlay and CloudFormation
stacks, the API gateway configuration, the monitoring stack and the scripts that tie them together.

## Repositories

| Repository | Role | Pipeline |
| --- | --- | --- |
| [Kongroo.Identity](https://github.com/almeidajr/Kongroo.Identity) | Users, authentication, JWT issuance (UsersAPI) | [![CI/CD](https://github.com/almeidajr/Kongroo.Identity/actions/workflows/ci-cd.yml/badge.svg?branch=master)](https://github.com/almeidajr/Kongroo.Identity/actions/workflows/ci-cd.yml) |
| [Kongroo.Catalog](https://github.com/almeidajr/Kongroo.Catalog) | Games, promotions, orders, library, **Game Search (Elasticsearch)**, **reviews (MongoDB)**, **cache (Redis)** (CatalogAPI) | [![CI/CD](https://github.com/almeidajr/Kongroo.Catalog/actions/workflows/ci-cd.yml/badge.svg?branch=master)](https://github.com/almeidajr/Kongroo.Catalog/actions/workflows/ci-cd.yml) |
| [Kongroo.Payments](https://github.com/almeidajr/Kongroo.Payments) | Payment simulation (PaymentsAPI) | [![CI/CD](https://github.com/almeidajr/Kongroo.Payments/actions/workflows/ci-cd.yml/badge.svg?branch=master)](https://github.com/almeidajr/Kongroo.Payments/actions/workflows/ci-cd.yml) |
| [Kongroo.Notifications](https://github.com/almeidajr/Kongroo.Notifications) | **AWS Lambda** triggered by SQS (serverless NotificationsAPI) + SAM template | [![CI/CD](https://github.com/almeidajr/Kongroo.Notifications/actions/workflows/ci-cd.yml/badge.svg?branch=master)](https://github.com/almeidajr/Kongroo.Notifications/actions/workflows/ci-cd.yml) |
| [Kongroo.Orchestration](https://github.com/almeidajr/Kongroo.Orchestration) | This repo: compose, k8s, EKS, Kong, Prometheus/Grafana, scripts, docs | no pipeline: manifests reach EKS through `eks/apply.ps1` |

Architecture reference: [ARCHITECTURE.md](./ARCHITECTURE.md). Cloud-day runbook: [eks/README.md](./eks/README.md).

## Phase 4 requirements: where to find them

| Statement | What | Where |
| --- | --- | --- |
| §1 Managed infrastructure | AWS EKS cluster, CloudFormation | [Stack choices](#phase-4-stack-the-choices), [Run on EKS](#3-aws-eks-the-cloud-day), `eks/cluster-stack.yaml`, `eks/kustomization.yaml` |
| §1 Registry | Amazon ECR, images tagged with the commit SHA | `eks/registry-stack.yaml`, [CI/CD](#cicd) |
| §1 External access | Kong behind a Classic Load Balancer (`Service` type `LoadBalancer`) | `k8s/kong/service.yaml`, [Endpoints](#endpoints-and-ports) |
| §2 NoSQL | Catalog reviews in MongoDB through `MongoDB.Driver` | [Stack choices](#phase-4-stack-the-choices), Kongroo.Catalog `GetGameReviewsQueryHandler`, `SubmitReviewCommandHandler` |
| §2 Distributed cache | Catalog `HybridCache` over `IDistributedCache` (StackExchange.Redis provider) | [Cache demo](#cache-demo), Kongroo.Catalog `ServiceCollectionExtensions` |
| §3 Advanced search | Elastic Cloud, indexing in CatalogAPI, fuzzy `/search` sorted by relevance | [Search](#search) |
| §4 CI/CD and GitOps | One GitHub Actions workflow per service, rolling update on EKS | [CI/CD](#cicd), each repo's `.github/workflows/ci-cd.yml` |
| §5 Secrets | Nothing committed; Kubernetes Secrets injected at runtime | [Secrets](#secrets) |
| Deliverable: code | NoSQL and cache drivers, infrastructure YAML, pipeline YAML | Kongroo.Catalog; `k8s/`, `eks/*.yaml`, Notifications `template.yaml`; `.github/workflows/ci-cd.yml` in each service repo |
| Deliverables: video and report | Submitted through the FIAP portal; the report links this README | — |

## Prerequisites

- **Docker**: Rancher Desktop on this project's machine (with Kubernetes enabled for the k3s path).
- **PowerShell 7**: every script is `#requires -Version 7`.
- **kubectl**: for local k3s and EKS.
- **.NET 10 SDK**: only to build the service images from source or run a service on the host.
- **Local k3s and EKS**: an AWS Academy Learner Lab account and the AWS CLI v2. EKS also needs `gh` logged in with admin rights on
  the four service repos.

## Phase 4 stack: the choices

| Requirement | Choice | Why | Where |
| --- | --- | --- | --- |
| Managed Kubernetes | **Amazon EKS** (us-east-1), 2 × t3.medium, pods on the node's `LabRole` through IMDS | The Learner Lab offers EKS but no IRSA or Pod Identity, so pods borrow the node role and no AWS key lives in the cluster | `eks/cluster-stack.yaml` |
| Registry | **Amazon ECR**, one repository per API | The cloud's native private registry, in its own long-lived stack so images survive each day's cluster teardown | `eks/registry-stack.yaml` |
| Infrastructure as code | **CloudFormation** (registry and cluster stacks) + a **Kustomize overlay** on the local manifests | CloudFormation needs no state backend in a lab account; the overlay keeps one description of the system for k3s and EKS | `eks/` |
| Search | **Elasticsearch 9.5.x on Elastic Cloud** (us-east-1); 9.5.5 locally, the newest 9.5.x in the cloud | OpenSearch is blocked in the Learner Lab; Elastic Cloud is managed, and the local single node runs the same 9.5 line | Kongroo.Catalog, `k8s/elasticsearch` |
| NoSQL | **MongoDB 8** for game reviews via `MongoDB.Driver` | Reviews are free-form, high-volume documents read per game, a natural document model | `k8s/mongodb`, Catalog `POST/GET /games/{id}/reviews` |
| Cache | **Redis 8**: Catalog `HybridCache` over `IDistributedCache` (StackExchange provider), in-process L1 + Redis L2 | The ASP.NET Core abstraction gives stampede protection and tag invalidation; the mode is one environment variable, so its effect can be measured | `k8s/redis`, [Cache demo](#cache-demo) |
| CI/CD | **GitHub Actions** + **Trivy** (secret scan of the repo, CRITICAL scan of the image) | Lives next to the code, one self-contained workflow per service, free on public repos | `.github/workflows/ci-cd.yml` in each service repo |
| Secrets | **Kubernetes Secrets** created by `scripts/new-secrets.ps1` from a git-ignored env file | No paid secret manager in the lab; Secrets created outside git leave no credential in any YAML | [Secrets](#secrets) |
| API gateway | **Kong Gateway 3.9 (OSS), DB-less**, `jwt` plugin (HS256), `prometheus` plugin | One entry point and JWT checked at the edge; the same `kong.yaml` serves compose, k3s and EKS | `k8s/kong/kong.yaml` |
| Messaging | MassTransit: **RabbitMQ** in compose and tests, **Amazon SNS/SQS** on k3s and EKS (`Messaging__Transport`) | The Lambda subscribes to SNS, and a config switch keeps compose cloud-free | service ConfigMaps |
| Serverless | **AWS Lambda (.NET 10)** triggered by **SQS**, deployed with **SAM** by its own pipeline | Notifications is event-driven and idle most of the time | Kongroo.Notifications `template.yaml` |
| Observability | **Prometheus + Grafana**; OpenTelemetry `/metrics` on the three APIs; Kong metrics | Runs in the cluster at no extra cost, with a Catalog latency panel for the cache demo | `k8s/prometheus`, `k8s/grafana` |

## Three ways to run

Docker Compose and local k3s share the host ports (8000, 3000, 9090 among others), so run only one of them at a time.

| Mode | What runs | Messaging | Notifications |
| --- | --- | --- | --- |
| **1. Docker Compose** | Kong, 3 APIs (built from source), Postgres, RabbitMQ, MongoDB, Redis, Elasticsearch, Prometheus, Grafana | RabbitMQ | not fired (the Lambda lives in AWS) |
| **2. Local k3s** | the same, as Kubernetes manifests, APIs at CI-built images | Amazon SNS/SQS (Learner Lab keys) | Lambda logs in CloudWatch |
| **3. AWS EKS** | the k3s manifests through the EKS overlay: APIs × 2 from ECR, no RabbitMQ, search on Elastic Cloud | Amazon SNS/SQS (node `LabRole`) | Lambda logs in CloudWatch |

Required sibling layout (compose build contexts and `sync.ps1` are relative):

```
repos/
  Kongroo.Identity/
  Kongroo.Catalog/
  Kongroo.Payments/
  Kongroo.Notifications/
  Kongroo.Orchestration/   ← this repo
```

### 1. Docker Compose (fresh clone)

```powershell
foreach ($repo in "Identity", "Catalog", "Payments", "Notifications", "Orchestration") {
    git clone "https://github.com/almeidajr/Kongroo.$repo"
}
cd Kongroo.Orchestration
./scripts/new-secrets.ps1 -SkipKubernetes   # every local credential, see Secrets below
docker compose up --build -d
./scripts/demo.ps1                          # register → login → publish game → buy → review, all via Kong
```

`-SkipKubernetes` leaves the cluster alone; `-SkipUserSecrets` skips the APIs' user-secrets on a machine without the .NET SDK.
If `docker compose up` from Windows fails with "invalid volume specification" (Windows-path bind mounts on Rancher Desktop's
WSL-hosted engine), run the same command from a WSL shell in this folder.
Compose reads `.env` on its own and stops with "run scripts/new-secrets.ps1" when it is missing. `init-db.sql` creates the three
PostgreSQL databases on the first start (`docker compose down -v` to reset).

Volumes created before `new-secrets.ps1` existed hold the old committed passwords, and the APIs fail to authenticate against them.
Delete them once: `docker compose down -v`, and `kubectl delete namespace kongroo` for k3s, then run `new-secrets.ps1` again. The
same applies whenever `.env` is deleted.

### 2. Local k3s + AWS Academy Learner Lab

Clone as above, then:

1. **Start the lab** and paste **AWS Details → AWS CLI** into `~/.aws/credentials` (`[default]` profile).
2. **Deploy the cluster**: `./scripts/new-secrets.ps1` (creates the namespace and every Secret; safe to rerun), then
   `kubectl apply -k k8s/`.
3. **Load the session credentials** into the cluster. **Run this after every `kubectl apply -k k8s/`** (the apply resets the Secret
   to placeholders) **and after every new lab session**: `./scripts/set-aws-credentials.ps1` writes the `aws-credentials` Secret and
   restarts the three APIs. The `masstransit-bus` health check is in the `ready` set, so stale credentials keep the API pods out of
   Kong and Prometheus until this script runs; a loud failure beats a pod that serves with a dead bus.
4. **Check**: `kubectl -n kongroo get pods` (all `1/1 Running`), then `./scripts/demo.ps1 -AdminUsername admin`.

   On a cold cluster the three API pods restart exactly once: they start before Postgres accepts connections, the startup
   migration fails and the host stops; Kubernetes restarts them and they come up clean. That single restart is expected.
5. **Watch the Lambda**: `aws logs tail /aws/lambda/kongroo-notifications --follow`.

Local k3s uses the lab account's SNS topics and SQS queues, and the `kongroo-notifications` stack that the first cloud day's
`eks/up.ps1` deployed (it stays up between cloud days). EKS uses the same queues, so stop local k3s (or leave it on old keys)
during a cloud day: two stacks on the current keys compete for the same messages.

Images are pulled from Docker Hub, `josealmeidajr/kongroo-<service>:<commit SHA>`, pinned in `k8s/kustomization.yaml` to each
service's `master` SHA as it ran on EKS after the first cloud day. These tags serve local k3s only; production runs each repo's
`master` HEAD (see [CI/CD](#cicd)). To move k3s forward, bump the SHAs (each one pushed to Docker Hub by its pipeline), run
`./sync.ps1` if a service's `k8s/` folder changed, then repeat steps 2 and 3 (`kubectl apply -k k8s/`, `./scripts/set-aws-credentials.ps1`).

### 3. AWS EKS: the cloud day

A Learner Lab session lasts four hours and the nodes bill while they run, so the cluster lives for one cloud day: brought up from
nothing, then torn down to zero. The ECR registry stack and the `kongroo-notifications` stack stay between days.
**[eks/README.md](./eks/README.md) is the runbook** (bring-up, smoke, seed, teardown, recovery, video day); follow it rather than
this summary. The `eks/*.ps1` scripts it drives are listed under [Scripts](#scripts). `-LocalSearch` on `up.ps1` / `apply.ps1` is
the degraded search mode for a lapsed Elastic Cloud trial: Catalog searches the in-cluster Elasticsearch instead.

Seeding the demo catalog on EKS signs in through that day's Kong with that day's admin password, both from `eks/.env`:

```powershell
$eks = Get-Content -Raw eks/.env | ConvertFrom-StringData
./scripts/seed-games.ps1 -Gateway $eks.KONG_URL -AdminPassword $eks.BOOTSTRAP_ADMIN_PASSWORD -Context kongroo-eks
```

Every EKS `kubectl` call passes `--context kongroo-eks`, so the current context stays on local k3s. The day's Kong hostname
changes every day and is never committed; docs write it as `<kong-lb-hostname>`.

## CI/CD

Each service repo has one self-contained workflow, `.github/workflows/ci-cd.yml` (Identity, Catalog and Payments near-identical;
Notifications its own), triggered by pull requests to `master`, pushes to `master` and `workflow_dispatch`. Every third-party action
is pinned to a full commit SHA.

| Stage | APIs (Identity, Catalog, Payments) | Notifications |
| --- | --- | --- |
| Build & test | locked restore → `dotnet csharpier check .` → build (warnings as errors) → unit, integration and specs tests (Testcontainers) | locked restore → CSharpier check → build → unit tests |
| Security | Trivy secret scan of the repository (fails the run), then a Trivy scan of the image (fails on a fixable CRITICAL) | Trivy secret scan |
| Package | `docker build`, tagged with the full commit SHA (no `latest`) | `sam build` |
| Publish (`master` only) | push to Docker Hub `josealmeidajr/kongroo-<service>:<sha>`; then to ECR when armed | — |
| Deploy (`master`, when armed) | `kubectl set image` to the ECR image and `kubectl rollout status` | `sam deploy` of stack `kongroo-notifications` |

- **Production is each repo's `master` HEAD** (the statement's "main"; this project's branch is `master`). A push to `master`, or a
  `workflow_dispatch` run from `master`, builds, tests, scans and publishes the image, and on a cloud day rolls it out to EKS. On a
  fresh cluster, `eks/up.ps1` renders the overlay at each repo's `master` SHA and dispatches the pipeline for any image missing from
  ECR. This is pipeline-driven deployment, not pull-based GitOps: no commit records the running tag, and
  `kubectl --context kongroo-eks -n kongroo get deploy -o wide` shows it.
- **Gates and arming:** the ECR push and the deploy job run only when the repo variable `ECR_REGISTRY` is set (`SAM_DEPLOY=true` for
  Notifications), with the lab's session keys as repo secrets. `eks/arm.ps1` sets them on all four repos (`up.ps1` runs it; rerun it
  after every Start Lab press) and `eks/down.ps1` deletes them, so between cloud days `master` stays green and stops at Docker Hub.
  Stale lab keys fail the run red with "Lab credentials expired: run eks/arm.ps1".
- **Zero downtime:** `RollingUpdate` with `maxUnavailable: 0` / `maxSurge: 1`, readiness on `/health/ready`, a `preStop` sleep of 5 s,
  and two replicas of each API on EKS. Deploys are serialized per repo without cancelling a running one.
- **Manifest-only changes** (a ConfigMap, probes, replicas) are not deployed by a pipeline: run `./eks/apply.ps1` on the cloud day.
- CI's Mongo tests run `mongo:8.2` (`MONGO_TEST_IMAGE`) because `mongo:8.0` refuses the hosted runners' kernel; compose, k3s and EKS
  stay on `mongo:8.0`.

## Search

`GET /catalog/search?q=…&limit=…` (any authenticated user, through Kong) is Catalog's **Game Search**: a `multi_match` over title
(boosted ×3) and description with `fuzziness: AUTO`, only **Published** games, sorted by score. `limit` defaults to 20, maximum 50; a
blank `q` answers 400, and 503 while Elasticsearch is down (the rest of Catalog keeps working).

```powershell
$token = (Invoke-RestMethod -Method POST -Uri http://localhost:8000/identity/tokens -ContentType application/json `
    -Body (@{ username = "admin"; password = "<BOOTSTRAP_ADMIN_PASSWORD>" } | ConvertTo-Json)).accessToken   # compose: "developer"
Invoke-RestMethod "http://localhost:8000/catalog/search?q=lighthuose&limit=5" -Headers @{ Authorization = "Bearer $token" }
```

The misspelled `lighthuose` finds the seeded "… Lighthouse" games (`scripts/seed-games.ps1`); each hit carries `id`, `title`,
`description`, `priceAmount`, `currency` and `score`.

- **Indexing is asynchronous.** Every game create, update and delete publishes `GameIndexRequested` through Catalog's EF Core bus
  outbox, atomically with the write; Catalog consumes it, reloads the game and upserts or deletes its document in the `games` index,
  retrying with backoff for about two minutes before the message lands in the `_error` queue. A change shows in search within seconds.
- **Rebuild:** on startup Catalog creates the `games` index when it is missing and backfills it from Postgres. To rebuild, stop
  Catalog, delete the index and start Catalog again (commands in Kongroo.Catalog's README, "Game Search"). Each cloud day,
  `eks/up.ps1` deletes the Elastic Cloud index so Catalog rebuilds it from that day's data.

## Cache demo

Catalog caches `GET /games`, `GET /games/{id}` and `GET /games/{id}/reviews` (the most expensive read) through `HybridCache`: Redis
for 5 minutes, in-process L1 for 1 minute, evicted by the `games` tag on every game or promotion write and by key on a new review.
One environment variable on `deployment/catalog-api` picks the mode:

| Mode | `HybridCache__DefaultEntryOptions__Flags` |
| --- | --- |
| off | `DisableLocalCache, DisableDistributedCache` |
| Redis only | `DisableLocalCache` |
| L1 + Redis (default) | unset |

```powershell
./scripts/seed-games.ps1        # once: 500 games, reviews on 4 showcase games; prints their ids (k3s: -Context <your k3s context>)
kubectl -n kongroo set env deployment/catalog-api "HybridCache__DefaultEntryOptions__Flags=DisableLocalCache, DisableDistributedCache"
kubectl -n kongroo rollout status deployment/catalog-api
# k6, one run per mode (60 s at 10 requests/s per route); TOKEN is an admin token as in Search above
docker run --rm -e TOKEN=$token -e SHOWCASE=<ids printed by seed-games.ps1> -e "K6_SCRIPT=$(Get-Content -Raw load/catalog-cache.js)" `
    --entrypoint sh grafana/k6:1.3.0 -c 'printf "%s" "$K6_SCRIPT" > /tmp/catalog-cache.js && k6 run /tmp/catalog-cache.js'
kubectl -n kongroo set env deployment/catalog-api "HybridCache__DefaultEntryOptions__Flags=DisableLocalCache"   # Redis only
kubectl -n kongroo set env deployment/catalog-api HybridCache__DefaultEntryOptions__Flags-                       # back to L1 + Redis
kubectl -n kongroo exec deploy/redis -- redis-cli --scan                                                        # the cached keys
```

- **Grafana panel:** dashboard **Kongroo** → **Catalog latency (p50 / p95) by route**, server side, per route. Local:
  http://localhost:3000/d/kongroo. EKS: `kubectl --context kongroo-eks -n kongroo port-forward service/grafana 13000:3000`, then
  http://localhost:13000/d/kongroo.
- **On EKS** add `--context kongroo-eks` to every `kubectl`, take the token from that day's Kong with `BOOTSTRAP_ADMIN_PASSWORD` from
  `eks/.env`, and pass `-e GATEWAY=<KONG_URL from eks/.env>` to k6. There the k6 numbers include the laptop's round trip to us-east-1
  (about 125 ms), which flattens the gap: read the cache's effect on the Grafana panel. On the first cloud day the reviews read's
  server-side p95 went from 166 ms (off) to 8.8 ms (Redis only) to 4.8 ms (L1 + Redis).

## Endpoints and ports

| Component | Compose | Local k3s | EKS | Notes |
| --- | --- | --- | --- | --- |
| **Kong proxy (single entry point)** | http://localhost:8000 | http://localhost:8000 (LoadBalancer 8000; Traefik owns 80 on Rancher Desktop) | `http://<kong-lb-hostname>:8000` (Classic LB; `KONG_URL` in `eks/.env`) | `/identity/**`, `/catalog/**`, `/payments/**` |
| Kong status + metrics | http://localhost:8100/metrics | in-cluster `kong-status:8100` | same | scraped by Prometheus |
| Grafana | http://localhost:3000/d/kongroo | http://localhost:3000/d/kongroo | `port-forward service/grafana 13000:3000` | anonymous Viewer; `admin` / `GRAFANA_ADMIN_PASSWORD` from `.env` (`eks/.env` on EKS) |
| Prometheus | http://localhost:9090 | `kubectl -n kongroo port-forward svc/prometheus 9090` | same, with `--context kongroo-eks` | targets: identity-api, catalog-api, payments-api, kong |
| RabbitMQ UI | http://localhost:15672 | `port-forward svc/rabbitmq 15672` | none (SNS/SQS) | `kongroo` / `RABBITMQ_PASSWORD` from `.env` |
| identity-api / catalog-api / payments-api | 5101 / 5102 / 5103 (direct, dev only) | ClusterIP 8080; go through Kong | 2 replicas each, ClusterIP 8080 | |
| postgres / mongodb / redis | 5432 / 27017 / 6379 | ClusterIP | ClusterIP, EBS `gp3` volumes | |
| elasticsearch | http://localhost:9200 | ClusterIP 9200 | Elastic Cloud (in-cluster with `-LocalSearch`) | `elastic` / `ELASTIC_PASSWORD` from `.env`; plain HTTP, `elasticsearch:9.5.5` |

On Rancher Desktop's k3s, `kubectl port-forward` can fail with `socat not found`. Query Prometheus from Grafana's **Explore** instead
(signed in as `admin`); the RabbitMQ UI has nothing to show there, since k3s runs on SNS/SQS.

### Gateway routes

| Public path | Upstream | JWT verified at Kong |
| --- | --- | --- |
| `POST /identity/users`, `POST /identity/tokens` | identity-api | no (register, login) |
| `/identity/**` (everything else) | identity-api | yes |
| `/catalog/**`, including `GET /catalog/search` | catalog-api | yes |
| `/payments/**` | payments-api | yes |

Kong validates the HS256 signature and `exp` against the shared signing key `JWT_SIGNING_KEY`, then forwards the `Authorization`
header so each service still validates the token itself. The committed `k8s/kong/kong.yaml` holds only the placeholder
`__JWT_SIGNING_KEY__`; Kong's start command substitutes the key from its environment (`.env` in compose, `kong-secret` in
Kubernetes, where the file is a `configMapGenerator`) into a temporary copy and starts from that.

## SNS/SQS topology

The CloudFormation stack `kongroo-notifications` (`us-east-1`, role `LabRole`), deployed by Notifications' pipeline, creates the SNS
topics `kongroo-user-created` and `kongroo-payment-processed`, the SQS queue `kongroo-notifications` and its dead-letter queue
`kongroo-notifications-dlq` (3 receives → DLQ). On a lab account without that stack, `eks/up.ps1` deploys it before any API starts
(deleting copies of those two topics an earlier day's APIs left behind, which CloudFormation would refuse). The services create the
rest of the topology themselves at bus start: topics `kongroo-order-placed` and `kongroo-game-index-requested` (Catalog-internal) and
the consumer queues. The topic `kongroo-user-role-changed` only appears once a role change is actually published, because MassTransit
creates publish topics lazily, so its absence on a fresh stack is expected, not a failure.

## Repository layout

```
k8s/                            the k3s base, shared by local k3s and EKS
  kustomization.yaml            namespace, resources, images (Docker Hub SHA tags), configMapGenerators
  namespace.yaml
  aws-credentials.secret.yaml   placeholders, refreshed by scripts/set-aws-credentials.ps1 (deleted by the EKS overlay)
  kong/                         kong.yaml (declarative, key placeholder, from a configMapGenerator), deployment, LoadBalancer service, status service
  prometheus/                   prometheus.yml (static targets), deployment, service
  grafana/                      provisioning (datasource, dashboard provider), dashboards/kongroo.json, deployment, service
  postgres/  rabbitmq/  mongodb/  redis/  elasticsearch/
                                no Secret manifests: scripts/new-secrets.ps1 creates them
  identity/  catalog/  payments/   ← generated by sync.ps1 from the service repos; do not edit
eks/                            the cloud: overlay on k8s/, CloudFormation stacks, cloud-day scripts, runbook
  kustomization.yaml            ECR images, replicas: 2, gp3 StorageClass, RabbitMQ and aws-credentials removed
  cloud-search/                 component that drops the local Elasticsearch (left out by -LocalSearch)
  registry-stack.yaml           ECR repositories (stays up)
  cluster-stack.yaml            VPC, two public subnets, EKS cluster, managed node group, add-ons (one per cloud day)
load/catalog-cache.js           k6 load for the cache demo
scripts/                        local scripts (see Scripts)
```

## Scripts

Each script's `Get-Help <script> -Full` is the source of truth for what it does and takes.

| Script | Purpose |
| --- | --- |
| `scripts/new-secrets.ps1` | Generates every local credential into `.env` (only if absent), sets the APIs' user-secrets and creates the Kubernetes Secrets; idempotent. `-Target Eks` writes a fresh `eks/.env` for the cloud day (run by `eks/up.ps1`) |
| `scripts/demo.ps1` | Drives every graded flow through Kong (compose defaults; `-AdminUsername admin` for k3s; `eks/smoke.ps1` runs it on EKS) |
| `scripts/seed-games.ps1` | Seeds the search and cache demos: 500 invented, deterministic published games through Kong, plus reviews on 4 showcase games straight into MongoDB; idempotent, `-Context` picks the cluster |
| `scripts/watch-release.ps1` | Watches a live Catalog deploy through Kong: one `GET /catalog/games/{id}` a second, printing status and the release header |
| `scripts/set-aws-credentials.ps1` | Copies the Learner Lab keys into local k3s and restarts the APIs |
| `scripts/check.ps1` | No `secret.yaml` anywhere, `kong config parse`, `kubectl kustomize`, the EKS overlay rendered (default and `-LocalSearch`), `docker compose config`, `cfn-lint` on `eks/*-stack.yaml` (needs `cfn-lint` on PATH, e.g. `uv tool install cfn-lint`), `sync.ps1 -Check` |
| `sync.ps1` | Regenerates `k8s/<service>/` from the sibling repos (`-Check` detects drift) |
| `eks/up.ps1` | Starts a cloud day: stacks, Secrets, CI armed, Notifications stack if missing, overlay at each `master` HEAD, Kong URL in `eks/.env` |
| `eks/smoke.ps1` | Proves the cloud day end to end: Kong load balancer, `demo.ps1`, the Lambda's confirmation log, a misspelled search |
| `eks/apply.ps1` | Renders the EKS overlay at each repo's `origin/master` SHA and applies it (manifest-only changes; `-DryRun` prints it) |
| `eks/arm.ps1` | Sets the lab keys and gate variables on the four service repos (`-Disarm` removes them); see [CI/CD](#cicd) |
| `eks/down.ps1` | Ends a cloud day: disarms CI, deletes the namespace and cluster stack, prints `safe to End Lab` only when nothing is left billing |

## Observability

- Identity, Catalog and Payments expose `/metrics` (OpenTelemetry → Prometheus exporter): ASP.NET Core request duration by route
  and status code, HttpClient, .NET runtime, MassTransit publish/consume.
- Kong exposes edge metrics per service/route on its status port.
- Prometheus scrapes four static targets every 15 s (`k8s/prometheus/prometheus.yml`), all UP: `identity-api`, `catalog-api`,
  `payments-api`, `kong`.
- Grafana provisions the **Kongroo** dashboard (uid `kongroo`): requests/s, error rate, p50/p95 latency, requests by status code,
  Kong requests and latency, MassTransit message rates (`messaging_masstransit_send_ea_total` /
  `messaging_masstransit_consume_ea_total`, where the OpenTelemetry Prometheus exporter appends the instrument unit, so a publish
  through the EF outbox is exported as a send), and Catalog p50/p95 by route for the cache demo.
- Lambda logs are in CloudWatch, the centralized platform for the serverless piece.

## Secrets

No password, key, token or connection string is committed, and no `secret.yaml` exists in any repo (`scripts/check.ps1` fails on
one; each pipeline's Trivy secret scan fails on a committed credential). Locally, `scripts/new-secrets.ps1` generates random values
into the git-ignored `.env` once and reuses them on every rerun; from that file it creates the Kubernetes Secrets in the current
context and sets the APIs' user-secrets (hosts rewritten to `localhost`). On EKS, each cloud day `eks/up.ps1` runs the same script
against the cluster with a fresh git-ignored `eks/.env`, so cloud and local never share a value. The pods read every credential from
Kubernetes Secrets at runtime (`envFrom`). Usernames, hostnames, issuer and audience are configuration, not secrets.

| Credential | Local source | Cloud source (EKS) | How it is injected |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose `${POSTGRES_PASSWORD}`; Secret `postgres-secret` |
| `RABBITMQ_PASSWORD` | `.env` | `eks/.env` (unused: the overlay drops RabbitMQ, EKS runs on SQS) | compose; Secret `rabbitmq-secret`; `RabbitMq__Pass` in each API's Secret and user-secrets |
| `MONGO_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose; Secret `mongodb-secret` |
| `GRAFANA_ADMIN_PASSWORD` | `.env` | `eks/.env`, new each cloud day | compose; Secret `grafana-secret` |
| `ELASTIC_PASSWORD` | `.env` | `eks/.env` (used only by the degraded `-LocalSearch` mode; otherwise Catalog uses Elastic Cloud) | compose; Secret `elasticsearch-secret`; Catalog `Search__Password` in `catalog-secret` and user-secrets |
| `JWT_SIGNING_KEY` (hex) | `.env` | `eks/.env`, new each cloud day | `Jwt__SigningKey` in `identity-secret`, `catalog-secret`, `payments-secret` and user-secrets; Kong reads it from `kong-secret` (compose: `.env`) and substitutes it into `kong.yaml` at start |
| `BOOTSTRAP_ADMIN_PASSWORD` | `.env` | `eks/.env`, new each cloud day | `BootstrapAdmin__Password` in `identity-secret` and user-secrets; `demo.ps1` and `seed-games.ps1` read it from `.env` |
| `IDENTITY_DATABASE_CONNECTION_STRING`, `CATALOG_DATABASE_CONNECTION_STRING`, `PAYMENTS_DATABASE_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | `ConnectionStrings__Database` in each API's Secret and user-secrets |
| `MONGO_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | Catalog `Mongo__ConnectionString` in `catalog-secret` and user-secrets |
| `REDIS_CONNECTION_STRING` | `.env` | `eks/.env`, new each cloud day | Catalog `ConnectionStrings__Redis` in `catalog-secret` and user-secrets |
| Elastic Cloud user (`kongroo-catalog`) | none: local search uses the `elastic` user above | `SEARCH_URI` / `SEARCH_USERNAME` / `SEARCH_PASSWORD` in the hand-filled, git-ignored `eks/cloud.env`; `eks/up.ps1` stops without it (`-LocalSearch` reads none of it) | `Search__Uri`, `Search__Username`, `Search__Password` in `catalog-secret`, which overrides `catalog-config` |
| AWS | Learner Lab session keys pasted into `~/.aws/credentials` | none in the cluster: pods use the node's `LabRole` through IMDS; CI gets the session keys as repository secrets from `eks/arm.ps1` | k3s: `scripts/set-aws-credentials.ps1` fills the `aws-credentials` Secret (committed with placeholders only); AWS SDK default credential chain |
| Docker Hub | none | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repository secrets | the pipeline's `docker login --password-stdin` |

Known trade-off: `new-secrets.ps1` passes values to `kubectl create secret --from-literal`, so they are briefly visible on the local
machine's process list while the script runs.
