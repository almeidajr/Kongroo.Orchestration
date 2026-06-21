# Kongroo.Orchestration

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

| Service | Local Port | Description |
|---|---|---|
| identity-api | 5101 | User registration and authentication |
| catalog-api | 5102 | Game catalog and user library |
| payments-api | 5103 | Payment processing |
| notifications-api | 5104 | Notifications (email simulation) |
| postgres | 5432 | PostgreSQL (all databases) |
| rabbitmq | 5672 / 15672 | Message broker (AMQP / management UI) |

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
