#requires -Version 7
<#
.SYNOPSIS
  Prove a cloud day works before seeding or recording: Kong's load balancer answers, the purchase flow passes, the Notifications
  Lambda logs the purchase confirmation, and a misspelled search finds the demo game.
.DESCRIPTION
  Reads KONG_URL and BOOTSTRAP_ADMIN_PASSWORD from eks/.env (written by up.ps1), waits for every pod in kongroo to be Ready, then
  runs the checks in order and stops at the first failure, naming it, with a non-zero exit code. The current kube context is never
  read or changed; the cluster is reached through context kongroo-eks.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/common.ps1"

function Invoke-Check([string]$Name, [scriptblock]$Check) {
    Write-Output "`n== $Name"
    try {
        & $Check
    }
    catch {
        Write-Output "SMOKE FAILED at '$Name': $($_.Exception.Message)"
        exit 1
    }
    Write-Output "OK: $Name"
}

function Wait-Until([string]$Description, [TimeSpan]$Timeout, [scriptblock]$Condition) {
    $deadline = (Get-Date) + $Timeout
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) { throw "$Description after $([int]$Timeout.TotalMinutes) minutes" }
        Start-Sleep -Seconds 10
    }
}

Invoke-Check "AWS credentials" {
    aws sts get-caller-identity | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: refresh credentials" }
}

$eksEnv = $null
Invoke-Check "eks/.env has KONG_URL and BOOTSTRAP_ADMIN_PASSWORD" {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) { throw "Not found: $envFile. Run eks/up.ps1 first." }
    $script:eksEnv = Get-Content -Raw $envFile | ConvertFrom-StringData
    if (-not $script:eksEnv.KONG_URL -or -not $script:eksEnv.BOOTSTRAP_ADMIN_PASSWORD) { throw "$envFile lacks KONG_URL or BOOTSTRAP_ADMIN_PASSWORD: rerun eks/up.ps1 after down.ps1." }
}
$gateway = $eksEnv.KONG_URL

Invoke-Check "every kongroo pod Ready" {
    kubectl --context $kubeContext -n kongroo wait --for=condition=Ready pod --all --timeout=15m
    if ($LASTEXITCODE -ne 0) { throw "pods not Ready: kubectl --context $kubeContext -n kongroo get pods" }
}

Invoke-Check "1. Kong load balancer resolves and answers" {
    $hostname = ([Uri]$gateway).Host
    # A fresh ELB name takes minutes to reach DNS; an anonymous call answered 401 proves Kong is behind it.
    Wait-Until -Description "$hostname did not resolve and answer 401 to an anonymous GET /catalog/games" -Timeout ([TimeSpan]::FromMinutes(15)) -Condition {
        try {
            [Net.Dns]::GetHostAddresses($hostname) | Out-Null
            (Invoke-WebRequest -Uri "$gateway/catalog/games" -SkipHttpErrorCheck -TimeoutSec 10).StatusCode -eq 401
        }
        catch { $false }
    }
}

$demoStartedAt = [DateTimeOffset]::UtcNow
$demo = $null
Invoke-Check "2. demo.ps1 purchase flow" {
    $script:demo = & "$root/scripts/demo.ps1" -Gateway $gateway -AdminUsername admin -AdminPassword $eksEnv.BOOTSTRAP_ADMIN_PASSWORD -PassThru
    if ($script:demo.OrderStatus -ne "paid") { throw "order $($script:demo.OrderId) is '$($script:demo.OrderStatus)', not paid" }
}

Invoke-Check "3. Notifications Lambda logged the purchase confirmation" {
    $logGroup = "/aws/lambda/kongroo-notifications"
    Wait-Until -Description "no purchase confirmation for order $($demo.OrderId) in $logGroup" -Timeout ([TimeSpan]::FromMinutes(5)) -Condition {
        # The order id is matched in --query, not the filter pattern: a hyphenated term needs embedded quotes, which aws.cmd mangles.
        $count = aws logs filter-log-events --region $region --log-group-name $logGroup `
            --start-time $demoStartedAt.ToUnixTimeMilliseconds() --filter-pattern confirmation `
            --query "length(events[?contains(message, 'purchase confirmation') && contains(message, '$($demo.OrderId)')])" --output text
        if ($LASTEXITCODE -ne 0) { throw "aws logs filter-log-events failed on $logGroup" }
        # The CLI paginates and applies --query per page, so text output is one count per page.
        ($count | Measure-Object -Sum).Sum -gt 0
    }
}

Invoke-Check "4. misspelled search finds the demo game" {
    $query = $demo.GameTitle.Remove(1, 1)
    $headers = @{ Authorization = "Bearer $($demo.PlayerToken)" }
    # Indexing runs through the outbox and a consumer, so the game reaches Elasticsearch a little after it is published.
    Wait-Until -Description "GET /catalog/search?q=$query did not return game $($demo.GameId)" -Timeout ([TimeSpan]::FromMinutes(3)) -Condition {
        try {
            $hits = Invoke-RestMethod -Uri "$gateway/catalog/search?q=$([Uri]::EscapeDataString($query))&limit=50" -Headers $headers
            $hits.id -contains $demo.GameId
        }
        catch { $false }
    }
    Write-Output "GET /catalog/search?q=$query returned game $($demo.GameId)"
}

Write-Output "`nSmoke passed against $gateway"
