# Cloud-day runbook

One cloud day of FIAP Cloud Games on EKS, from Start Lab to End Lab. The scripts in this folder do everything they can; this page
holds only what they can't: Start Lab, pasting the Learner Lab credentials, the Elastic Cloud console, waiting, and End Lab. Each step is
one command plus one check. Run everything from the repository root in PowerShell 7.

The cluster is reached only through kube context `kongroo-eks`; every command passes `--context kongroo-eks` (or `-Context kongroo-eks`)
and the current context stays on local k3s. The day's Kong address is `KONG_URL` in the git-ignored `eks/.env`, written by `up.ps1`; it
changes every day and is never committed. This page writes it as `<kong-lb-hostname>`, and Postman reads it through `{{baseUrl}}`.

Needs: `aws` CLI v2, `kubectl`, `gh` logged in with admin rights on the four service repos, `git` with the sibling repos cloned.

## Rules for every cloud day

- **After any Start Lab press** (starting the session or extending the timer), paste the new "AWS Details" block (step 1.2), then run
  `./eks/arm.ps1`. Do it every time, without checking whether the keys changed. Check: it prints `CI armed`. It also restarts the lab
  clock in `eks/.env` (`up.ps1` starts it), which `smoke.ps1`, `seed-games.ps1` and `watch-release.ps1` print as their first line:
  `Lab clock: <h:mm> since the last Start Lab; …`.
- **Extend at the 3-hour mark, every time:** when the Lab timer shows about 1:00 left, press Start Lab, then follow the rule above. A
  session that expires with the cluster up keeps billing: the node group replaces the stopped nodes.
- A script that stops with `refresh credentials` means the pasted keys are stale: Start Lab, step 1.2, rerun the script.

## 1. Bring-up

### First cloud day only: Elastic Cloud

The trial, its deployment and the `kongroo-catalog` user are created once, by hand, and stay up across cloud days at no cost. The trial
lasts 14 days: every cloud day must fit inside it.

1. **Start the trial.** Sign up at <https://cloud.elastic.co>. Check: the console shows the trial's end date; note it.
2. **Create the deployment** on AWS, region `us-east-1` (N. Virginia), version: the newest 9.5.x offered (local runs 9.5.5, which the
   cloud does not offer). Check: the deployment is healthy; copy its Elasticsearch endpoint (`https://…`).
3. **Create the role and user.** In the Elastic Cloud console, open the deployment's **API console** (or Dev Tools in its Kibana) and
   run:

   ```text
   PUT _security/role/kongroo-games
   { "indices": [ { "names": ["games"], "privileges": ["read", "write", "create_index", "delete_index", "view_index_metadata"] } ] }

   POST _security/user/kongroo-catalog
   { "password": "<a password you choose>", "roles": ["kongroo-games"] }
   ```

   Check: both answer `"created": true`. `view_index_metadata` lets Catalog check that `games` exists before each write (without it,
   indexing fails with `403 from: HEAD /games`). If the trial refuses the custom role, give the user the built-in `superuser` role instead
   (acceptable: the deployment holds nothing else).
4. **Fill `eks/cloud.env`** (git-ignored) with the endpoint and that user:

   ```text
   SEARCH_URI=https://<elasticsearch-endpoint>
   SEARCH_USERNAME=kongroo-catalog
   SEARCH_PASSWORD=<the password>
   ```

   Check: `git check-ignore eks/cloud.env` prints `eks/cloud.env`, and the user authenticates:

   ```powershell
   . ./eks/common.ps1; $cloud = Read-CloudEnv
   Invoke-RestMethod "$($cloud.SEARCH_URI)/_security/_authenticate" -Authentication Basic `
       -Credential ([pscredential]::new($cloud.SEARCH_USERNAME, (ConvertTo-SecureString $cloud.SEARCH_PASSWORD -AsPlainText -Force)))
   ```

   prints `username : kongroo-catalog`.

### Every cloud day

1. **Start Lab** in the Learner Lab. Check: the dot next to "AWS" turns green and the timer shows about 4:00.
2. **Paste the credentials:** copy the "AWS Details" → "AWS CLI" block into the `[default]` profile of `~/.aws/credentials`.

   ```powershell
   notepad $HOME/.aws/credentials
   ```

   Check: `aws sts get-caller-identity` answers with an `assumed-role/voclabs/…` ARN.
3. **Bring the day up** (about 20 minutes: stacks, Secrets, arming, the Notifications stack if missing, overlay, dispatches, Kong's load
   balancer). On a lab account without the `kongroo-notifications` stack (the first cloud day), it deploys that stack through
   Notifications' CI/CD before any API starts and waits for it (about 4 more minutes): the stack creates the two SNS topics the Lambda
   subscribes to, so `up.ps1` first deletes any copy an earlier day's APIs left behind.

   ```powershell
   ./eks/up.ps1
   ```

   Check: the last line is `Kong: http://<kong-lb-hostname>:8000 …`. If it stops with `Namespace kongroo already exists`, a previous day
   was not torn down: section 4, then rerun.
4. **Wait for the pipelines `up.ps1` dispatched** (only the repos it reported as `missing from ECR`):

   ```powershell
   "Identity", "Catalog", "Payments" | ForEach-Object { gh run list --repo "almeidajr/Kongroo.$_" --workflow ci-cd.yml --limit 1 }
   ```

   Check: each dispatched run is `completed` / `success` (about 5 minutes on a first day, when all three are missing), and
   `kubectl --context kongroo-eks -n kongroo get pods` shows no `ImagePullBackOff` (pods still starting are fine: `smoke.ps1` waits for
   them).

**Manifest-only change during the day:** `./eks/apply.ps1` (`-LocalSearch` on a degraded-search day, Recovery (d)) renders each API at its repo's `origin/master` SHA. If that SHA has no ECR
image yet (its pipeline is still running, or ran while CI was disarmed), the new pods sit in `ImagePullBackOff` while the old pods keep
serving. Run the repo's workflow first, wait for it to go green, then apply:

```powershell
gh workflow run ci-cd.yml --repo almeidajr/Kongroo.<Service> --ref master
```

## 2. Smoke

Proves the deployment works before seeding or recording: it waits for every `kongroo` pod to be Ready, then checks, in order, that
(1) Kong's load balancer resolves and answers (it retries while DNS propagates), (2) `scripts/demo.ps1` passes through it, (3) the
Notifications Lambda logged the purchase confirmation for the order the demo placed, and (4) a one-typo search finds the demo game
(it retries while indexing catches up).

```powershell
./eks/smoke.ps1
```

Check: the last line is `Smoke passed against http://<kong-lb-hostname>:8000`. Otherwise it stops at the first broken check with
`SMOKE FAILED at '<check>'` and a non-zero exit code. Where to look:

| Failed check | Look at |
| --- | --- |
| every kongroo pod Ready | `kubectl --context kongroo-eks -n kongroo get pods`, then `describe pod` on the one not Ready |
| 1. Kong load balancer | `kubectl --context kongroo-eks -n kongroo get service kong`; a new load balancer can take 5 minutes to resolve |
| 2. demo.ps1 | the step it printed last; `kubectl --context kongroo-eks -n kongroo logs deploy/<service>-api` |
| 3. Notifications Lambda | CloudWatch log group `/aws/lambda/kongroo-notifications`, the `kongroo-notifications-dlq` queue, stack `kongroo-notifications` (`log group does not exist`: the stack is missing; section 4, then 1.3; its SQS trigger `Disabled`: the lab's session-end sweep, `./eks/arm.ps1` re-enables it) |
| 4. search | `kubectl --context kongroo-eks -n kongroo logs deploy/catalog-api`; the deployment's health in the Elastic console |

## 3. Seed

Creates the demo catalog (500 invented, deterministic titles; the cache demo was measured at 500, and 1000 got the Catalog pod
liveness-killed during warm-up) and the showcase games' reviews.

```powershell
$eks = Get-Content -Raw eks/.env | ConvertFrom-StringData
./scripts/seed-games.ps1 -Gateway $eks.KONG_URL -AdminPassword $eks.BOOTSTRAP_ADMIN_PASSWORD -Context kongroo-eks
```

Check: it ends with `Showcase games (k6: -e SHOWCASE=…)` and their ids. It is idempotent: rerun it after any failure.

## 4. Teardown

1. **Tear down** (disarms CI, deletes the namespace with Kong's load balancer and the volumes, deletes the cluster stack, then proves
   nothing is left billing). The `kongroo-registry` and `kongroo-notifications` stacks stay.

   ```powershell
   ./eks/down.ps1
   ```

   Check: the last line ends with `safe to End Lab`. Anything else (for example `NOT safe to End Lab`): fix what it names and rerun it.
2. **End Lab**, only after that line. Check: the dot next to "AWS" turns red.

## 5. Recovery

**(a) The session expired with the cluster up** (the node group replaced the stopped nodes). Start Lab, paste the credentials (1.2), then:

```powershell
./eks/arm.ps1
```

Check: `kubectl --context kongroo-eks -n kongroo get pods` shows every pod `Running` and Ready. A datastore pod stuck `Pending`: (b).

**(b) A datastore pod is `Pending` on an AZ-pinned volume** (`kubectl --context kongroo-eks -n kongroo describe pod <pod>` says
`volume node affinity conflict`: its node was replaced in the other zone). Its data is lost; delete the claim and the pod, then
recreate the claim from its base manifest (the overlay does not change it; `<name>` is `postgres` or `mongodb`):

```powershell
kubectl --context kongroo-eks -n kongroo delete pvc <name>-pvc --wait=false
kubectl --context kongroo-eks -n kongroo delete pod -l app=<name>
kubectl --context kongroo-eks -n kongroo wait --for=delete pvc/<name>-pvc --timeout=2m
kubectl --context kongroo-eks -n kongroo apply -f k8s/<name>/pvc.yaml
```

Check: `kubectl --context kongroo-eks -n kongroo get pods` shows it Ready again. If it was `postgres`, restart the APIs so their startup
migrations recreate the schemas (`kubectl --context kongroo-eks -n kongroo rollout restart deployment identity-api catalog-api payments-api`).
Then rerun section 3.

**(c) The cluster stack failed** (`up.ps1` stops with `Stack kongroo-cluster failed`; CloudFormation shows `CREATE_FAILED` or
`ROLLBACK_COMPLETE`). Read the stack's events in the CloudFormation console, then:

```powershell
./eks/down.ps1; ./eks/up.ps1
```

Check: `down.ps1` prints `safe to End Lab`, then `up.ps1` ends with the `Kong:` line. Continue at 1.4.

**(d) The Elastic Cloud trial lapsed** (the console says the trial ended; smoke check 4 fails). Never start a second trial: run the day in
degraded search mode, with Catalog searching the in-cluster Elasticsearch: `./eks/up.ps1 -LocalSearch` (after `./eks/down.ps1` if the
cluster is up; it needs no `eks/cloud.env`). Check: section 2 passes, search check included.

## 6. Video day

Start from a fresh session; the whole day fits in one 4-hour session if the timer is extended at the 3-hour mark.

1. **Fresh session:** Start Lab and paste the credentials (1.1, 1.2). Check: `aws sts get-caller-identity` answers.
2. **Trial still valid:** open the Elastic Cloud console. Check: the trial's end date is after today and the deployment is healthy.
   Otherwise: Recovery (d).
3. **Bring-up, Smoke, Seed:** 1.3, 1.4, section 2, section 3. Check: `Smoke passed` and the showcase ids printed.
4. **Cache in its default mode** (L1 + Redis):

   ```powershell
   kubectl --context kongroo-eks -n kongroo set env deployment/catalog-api --list | Select-String HybridCache
   ```

   Check: no output (`HybridCache__DefaultEntryOptions__Flags` is unset). If it prints a line, unset it with
   `kubectl --context kongroo-eks -n kongroo set env deployment/catalog-api HybridCache__DefaultEntryOptions__Flags-`.
5. **Start the release watcher** in its own terminal, before any live push:

   ```powershell
   ./scripts/watch-release.ps1 -Gateway (Get-Content -Raw eks/.env | ConvertFrom-StringData).KONG_URL
   ```

   Check: it prints a line per second with status `200`.
6. **Record.** Check: the recording is saved locally. Before tearing down, repeat step 4 if the cache segment changed the mode.
7. **Teardown:** section 4, End Lab only after `safe to End Lab`.

## Budget

Three cloud days, each about $1–2 (two t3.medium nodes, the EKS control plane and one Classic load balancer for a few hours), all inside
the 14-day Elastic trial:

1. **First EKS deployment:** run this page top to bottom, fix what breaks in the repo it belongs to, and update this page with it.
2. **Dress rehearsal:** section 6 with the whole video script, untimed.
3. **Video day:** section 6.

Days 2 and 3 may merge if day 1 goes cleanly. Between cloud days nothing bills: only the ECR registry and the `kongroo-notifications`
stack stay up.
