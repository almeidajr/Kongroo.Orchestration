#requires -Version 7
<#
.SYNOPSIS
  Start a cloud day: the registry and cluster stacks, the day's Secrets, each API at its master HEAD on kongroo-eks, CI armed,
  and the Kong URL written to eks/.env.
.DESCRIPTION
  Needs the Learner Lab keys in ~/.aws/credentials and the hand-filled eks/cloud.env. Every value in eks/.env is new on each run,
  so rerunning it on a live cluster leaves the datastores on the old passwords: run down.ps1 first. The current kube context is
  never changed; the cluster is reached through context kongroo-eks.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$region = "us-east-1"
$kubeContext = "kongroo-eks"

aws sts get-caller-identity | Out-Null
if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: refresh credentials" }

$cloudEnvFile = Join-Path $PSScriptRoot "cloud.env"
if (-not (Test-Path $cloudEnvFile)) {
    throw "$cloudEnvFile not found: fill it by hand with SEARCH_URI, SEARCH_USERNAME and SEARCH_PASSWORD of the Elastic Cloud kongroo-catalog user."
}

# No --role-arn: CloudFormation must call EKS as the creator (voclabs), or LabRole gets the admin entry and nodes cannot join (ADR 0001).
$stacks = [ordered]@{ "kongroo-registry" = "registry-stack.yaml"; "kongroo-cluster" = "cluster-stack.yaml" }
foreach ($stack in $stacks.GetEnumerator()) {
    Write-Output "Deploying stack $($stack.Key) (no-op when unchanged; the cluster takes about 20 minutes)"
    aws cloudformation deploy --region $region --stack-name $stack.Key --template-file (Join-Path $PSScriptRoot $stack.Value) --no-fail-on-empty-changeset
    if ($LASTEXITCODE -ne 0) { throw "Stack $($stack.Key) failed: read its events in the CloudFormation console, then run down.ps1 and up.ps1" }
}

$previousContext = kubectl config current-context 2>$null
try {
    aws eks update-kubeconfig --region $region --name kongroo --alias $kubeContext
    if ($LASTEXITCODE -ne 0) { throw "aws eks update-kubeconfig failed" }
}
finally {
    # update-kubeconfig switches to the new context; local scripts expect the previous one.
    if ($previousContext) { kubectl config use-context $previousContext | Out-Null }
}

& "$root/scripts/new-secrets.ps1" -Target Eks

# The day's Postgres starts empty, so yesterday's documents must go; Catalog recreates the index and backfills it.
$cloud = ConvertFrom-StringData (Get-Content -Raw $cloudEnvFile)
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cloud.SEARCH_USERNAME):$($cloud.SEARCH_PASSWORD)"))
$response = Invoke-WebRequest -Method Delete -Uri "$($cloud.SEARCH_URI.TrimEnd('/'))/games" -Headers @{ Authorization = "Basic $basic" } -SkipHttpErrorCheck
if ($response.StatusCode -notin 200, 404) { throw "Deleting the Elastic Cloud games index returned $($response.StatusCode): $($response.Content)" }
Write-Output "Elastic Cloud games index cleared (HTTP $($response.StatusCode))"

& "$PSScriptRoot/apply.ps1"

# Armed before any dispatch: the dispatched run pushes to ECR and deploys only when ECR_REGISTRY and the keys are set.
& "$PSScriptRoot/arm.ps1"

# Only CI writes to ECR (ADR 0002): a master HEAD without an image gets its pipeline run, which pushes and rolls it out.
foreach ($name in "Identity", "Catalog", "Payments") {
    $repository = "kongroo-$($name.ToLowerInvariant())"
    $sha = (git -C (Join-Path (Split-Path $root -Parent) "Kongroo.$name") ls-remote origin refs/heads/master) -split "\s+" | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch "^[0-9a-f]{40}$") { throw "Cannot resolve origin/master of Kongroo.$name" }
    $output = aws ecr describe-images --region $region --repository-name $repository --image-ids "imageTag=$sha" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Output "$repository`:$sha is in ECR"; continue }
    if ("$output" -notmatch "ImageNotFoundException") { throw "aws ecr describe-images failed for $repository`: $output" }
    gh workflow run ci-cd.yml --repo "almeidajr/Kongroo.$name" --ref master
    if ($LASTEXITCODE -ne 0) { throw "gh workflow run failed for Kongroo.$name" }
    Write-Output "$repository`:$sha is missing from ECR: dispatched Kongroo.$name's CI/CD on master; its pods pull once it pushes"
}

Write-Output "Waiting for Kong's load balancer hostname"
$deadline = (Get-Date).AddMinutes(10)
do {
    $address = kubectl --context $kubeContext -n kongroo get service kong -o jsonpath="{.status.loadBalancer.ingress[0].hostname}:{.spec.ports[0].port}"
    $hasHostname = $address -match "^[^:]+:\d+$"
    if (-not $hasHostname) { Start-Sleep -Seconds 10 }
} until ($hasHostname -or (Get-Date) -gt $deadline)
if (-not $hasHostname) { throw "Service kong has no load balancer hostname after 10 minutes: kubectl --context $kubeContext -n kongroo describe service kong" }

$kongUrl = "http://$address"
[IO.File]::AppendAllText((Join-Path $PSScriptRoot ".env"), "KONG_URL=$kongUrl`n")
Write-Output "Kong: $kongUrl (KONG_URL in eks/.env; DNS can take a few minutes to resolve)"
