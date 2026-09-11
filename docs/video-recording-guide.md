# FIAP Phase 3 Video Recording Guide (≤ 20 minutes)

Goal: show the gateway routing and security, the serverless function firing with its logs, the
observability dashboard, and how NoSQL and the cache were integrated.

## Before recording

The Learner Lab session must be open and its credentials pasted into `~/.aws/credentials` **before**
the cluster starts — the `masstransit-bus` health check is in the `ready` set, so stale credentials
keep the API pods out of Kong and Prometheus. `kubectl apply -k k8s/` resets the Secret to
placeholders, so the refresh script always runs after it.

```powershell
cd D:\kongroo\Kongroo.Orchestration
kubectl apply -k k8s/
./scripts/set-aws-credentials.ps1      # always after the apply, and after every new lab session
kubectl -n kongroo get pods            # all 1/1 Running
./scripts/check.ps1                    # "In sync - no drift."
```

On a cold cluster the three API pods restart **once** — they start before Postgres accepts
connections, the startup migration fails, Kubernetes restarts them and they come up clean. Wait for
`1/1 Running` before recording; a `RESTARTS 1` column is expected and not worth explaining on camera.

Second terminal, in `D:\kongroo\Kongroo.Notifications`:

```powershell
sam logs --stack-name kongroo-notifications --name NotificationsFunction --tail
```

Browser tabs: <http://localhost:3000/d/kongroo> (Grafana, anonymous Viewer), and
<http://localhost:9090/targets> after `kubectl -n kongroo port-forward svc/prometheus 9090:9090`.
Optionally the AWS console → Lambda → `kongroo-notifications` → Monitor.

Kong answers on **port 8000** (Rancher Desktop's Traefik owns 80/443). Run Kubernetes *or* Docker
Compose, never both — they share the VM's host ports.

## Timeline

1. **Intro (1 min)** — the five repositories, one sentence of Phase 2 recap, then the Phase 3
   additions: Kong gateway, AWS Lambda on SQS, Prometheus + Grafana, MongoDB reviews, Redis cache.
2. **Repository tour (2 min)** — `k8s/kong/kong.yaml`, `k8s/prometheus`, `k8s/grafana`, `k8s/mongodb`,
   `k8s/redis`, the Notifications `template.yaml`, and in Catalog `Application/SubmitReviewCommandHandler.cs`
   and `Application/GamesCache.cs`.
3. **Gateway (4 min)** — `kubectl -n kongroo get svc kong`; `curl http://localhost:8000/catalog/games`
   → 401 from Kong; log in through `/identity/tokens`; repeat with the token → 200; tamper one
   character of the token → 401; show the routes and the `jwt` consumer in `kong.yaml`; point out that
   the service ClusterIPs are not reachable from outside.
4. **Serverless (4 min)** — run `./scripts/demo.ps1 -AdminUsername admin` and narrate the
   `sam logs --tail` terminal: the welcome line appears right after registration, the
   purchase-confirmation line after the order settles to `paid`. Then show `template.yaml`: the SQS
   trigger, `LabRole`, and the dead-letter queue after three failed receives.
5. **Observability (4 min)** — the Prometheus targets page with four targets UP
   (identity-api, catalog-api, payments-api, kong); the Grafana dashboard: requests per second, status
   codes, p95 latency, error rate, the Kong panels and the MassTransit send/consume rates. Optionally
   `curl` a service's `/metrics` through a port-forward to show the raw Prometheus text.
6. **NoSQL and cache (3 min)** — the demo's step [8] output (review created, then the summary with
   `count 1` and `averageRating 5`); the document in MongoDB:

   ```powershell
   kubectl -n kongroo exec deploy/mongodb -- mongosh -u kongroo -p development --quiet `
     --eval "db.getSiblingDB('kongroo_catalog').reviews.find().limit(3).toArray()"
   ```

   explain the unique index `ux_reviews_game_customer` (a second review by the same customer returns
   409) and the `$group` aggregation behind the summary. Then step [9]'s timings — the second read is
   roughly an order of magnitude faster — and the keys behind it:

   ```powershell
   kubectl -n kongroo exec deploy/redis -- redis-cli --scan --pattern "catalog:*"
   ```

   close with `HybridCache` and the `games` tag evicted in `UpdateGameCommandHandler`.
7. **Wrap-up (1 min)** — the README as the central guide, the repository links, and who did what.

Keep terminals at a large font and pre-type the long commands in a scratch file.
