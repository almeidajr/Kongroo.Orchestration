# <img alt="Kongroo" src="./logo.png" width="40"/> Kongroo.Orchestration

Central orchestration repository for FIAP Cloud Games Phase 2 microservices.

## Repository Layout

All service repos must be sibling directories of this repo:

```
repos/
  Kongroo.Identity/
  Kongroo.Catalog/
  Kongroo.Payments/
  Kongroo.Notifications/
  Kongroo.Orchestration/   ← this repo
```

## Services

| Service           | Local Port   | Description                           |
| ----------------- | ------------ | ------------------------------------- |
| identity-api      | 5101         | User registration and authentication  |
| catalog-api       | 5102         | Game catalog and user library         |
| payments-api      | 5103         | Payment processing                    |
| notifications-api | 5104         | Notifications (email simulation)      |
| postgres          | 5432         | PostgreSQL (all databases)            |
| rabbitmq          | 5672 / 15672 | Message broker (AMQP / management UI) |
| kong              | 8000         | API Gateway — single entry point (`/identity`, `/catalog`, `/payments`); same port in compose and k8s |
| kong-status       | 8100         | Kong status API and Prometheus metrics                                  |
| mongodb           | 27017        | MongoDB (Catalog reviews)                                               |
| redis             | 6379         | Redis (Catalog distributed cache)                                       |
| prometheus        | 9090         | Metrics (k8s: `kubectl port-forward svc/prometheus 9090`)              |
| grafana           | 3000         | Dashboards, anonymous viewer (`admin` / `development` to edit)          |

## Architecture Documentation

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the system overview, per-service diagrams, and event-flow sequence diagrams (Mermaid, rendered inline on GitHub).

## Running with Docker Compose

```bash
docker compose up --build
```

This starts all 4 application services, PostgreSQL, and RabbitMQ. The `init-db.sql` script creates the
required databases on first run.

### Publishing images to Docker Hub

compose tags built images as `josealmeidajr/kongroo-<service>:dev`. To publish them:

```bash
docker compose build
docker compose push
```

Kubernetes pulls the pinned `josealmeidajr/kongroo-<service>:<tag>` tags (centralized in `k8s/kustomization.yaml` under `images:`), which are published separately from the moving `:dev` tag used locally.

The RabbitMQ management UI is available at http://localhost:15672 (user `kongroo`, password `development`).

## Gateway

All client traffic goes through Kong (`k8s/kong/kong.yaml`, shared by compose and k8s):

| Public path | Upstream | JWT verified at Kong |
| --- | --- | --- |
| `POST /identity/users`, `POST /identity/tokens` | identity-api | no |
| `/identity/**` (everything else) | identity-api | yes |
| `/catalog/**` | catalog-api | yes |
| `/payments/**` | payments-api | yes |

Kong validates HS256 tokens issued by Identity (`iss` = `Kongroo.Identity.Api`) with the shared
development signing key held inline in `kong.yaml` (mounted from a Secret in k8s). Try it: `./scripts/demo.ps1` (compose) or
`./scripts/demo.ps1 -AdminUsername admin` (k8s — same `http://localhost:8000`, run one mode at a time).
Validate the repo with `./scripts/check.ps1`.

## Deploy to Kubernetes

The per-service manifests under `k8s/identity`, `k8s/catalog`, `k8s/payments`,
and `k8s/notifications` are **generated** from the sibling service repos by
`sync.ps1` — do not edit them by hand. Re-generate after any service-repo
manifest change:

```powershell
./sync.ps1            # regenerate k8s/<service>/ from ../Kongroo.*
./sync.ps1 -Check     # verify in sync (exit 1 on drift)
# -ReposRoot <path> if the service repos aren't in the parent directory
```

Deploy the whole stack (PostgreSQL, RabbitMQ, and the four services) into the
`kongroo` namespace with a single command:

```bash
kubectl apply -k k8s/
kubectl get pods -n kongroo
```

Kustomize creates the namespace and orders ConfigMaps/Secrets/Services before
Deployments automatically. Images are pulled from the pinned
`josealmeidajr/kongroo-<service>:<tag>` Docker Hub tags (centralized in
`k8s/kustomization.yaml` under `images:`).
