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

Kubernetes pulls the pinned `josealmeidajr/kongroo-<service>:0.0.1` tag (see `k8s/`), which is published separately from the moving `:dev` tag used locally.

The RabbitMQ management UI is available at http://localhost:15672 (user `kongroo`, password `development`).

## Deploying to Kubernetes (local cluster)

Update all passwords and signing keys in `k8s/**/secret.yaml` before applying.

```bash
kubectl apply -f k8s/postgres/
kubectl apply -f k8s/identity/
kubectl apply -f k8s/catalog/
kubectl apply -f k8s/payments/
kubectl apply -f k8s/notifications/

kubectl get pods
```

All pods should reach `Running` status within a few seconds.
