# Dot-sourced by the eks/ scripts, scripts/new-secrets.ps1 -Target Eks, seed-games.ps1 and watch-release.ps1.
$region = "us-east-1"
$cluster = "kongroo"
$kubeContext = "kongroo-eks"
$cloudEnvFile = Join-Path $PSScriptRoot "cloud.env"
$eksEnvFile = Join-Path $PSScriptRoot ".env"

# The Lab timer restarts at 4:00 on every Start Lab press, and arm.ps1 runs right after each one.
function Set-LabClock([datetime]$StartedAt, [string]$Path = $eksEnvFile) {
    if (-not (Test-Path $Path)) { return }
    $lines = @(Get-Content $Path | Where-Object { $_ -notmatch '^LAB_STARTED_AT=' })
    Set-Content $Path ($lines + "LAB_STARTED_AT=$($StartedAt.ToUniversalTime().ToString('o'))")
}

function Write-LabClock([string]$Path = $eksEnvFile, [datetime]$Now = (Get-Date)) {
    if (-not (Test-Path $Path)) { return }
    $startedAt = (Get-Content -Raw $Path | ConvertFrom-StringData).LAB_STARTED_AT
    if (-not $startedAt) { return }
    $elapsed = $Now.ToUniversalTime() - [datetime]::Parse($startedAt, [cultureinfo]::InvariantCulture, "RoundtripKind")
    # A clock past 4:00 belongs to a lab that has already ended.
    if ($elapsed -ge [TimeSpan]::FromHours(4)) { return }
    $advice = if ($elapsed -ge [TimeSpan]::FromHours(3)) { "PAST 3:00: Start Lab, paste the keys and run eks/arm.ps1 now, or start eks/down.ps1 before 3:30" }
    else { "extend at 3:00; start eks/down.ps1 by 3:30 at the latest" }
    "Lab clock: {0:h\:mm} since the last Start Lab; {1}" -f $elapsed, $advice
}

# Only Notifications' CI deploys the Lambda stack, and it must land before the APIs start: the stack creates the two topics it
# subscribes to, and CloudFormation refuses topics that already exist (MassTransit creates them on an API's first start).
function Install-NotificationsStack {
    $output = aws cloudformation describe-stacks --region $region --stack-name kongroo-notifications 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Output "Stack kongroo-notifications exists"; return }
    if ("$output" -notmatch "does not exist") { throw "aws cloudformation describe-stacks failed for kongroo-notifications: $output" }
    $account = aws sts get-caller-identity --query Account --output text
    foreach ($topic in "kongroo-user-created", "kongroo-payment-processed") {
        aws sns delete-topic --region $region --topic-arn "arn:aws:sns:${region}:${account}:$topic"
        if ($LASTEXITCODE -ne 0) { throw "aws sns delete-topic failed for $topic" }
    }
    $runUrl = gh workflow run ci-cd.yml --repo "almeidajr/Kongroo.Notifications" --ref master
    if ($LASTEXITCODE -ne 0) { throw "gh workflow run failed for Kongroo.Notifications" }
    Write-Output "Stack kongroo-notifications is missing: deploying it through Kongroo.Notifications's CI/CD ($runUrl)"
    gh run watch ($runUrl -split "/")[-1] --repo "almeidajr/Kongroo.Notifications" --exit-status --interval 20 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Kongroo.Notifications's CI/CD failed: $runUrl" }
}

# EKS can refuse the cluster delete with 409 "update in progress" right after the stack removes its add-ons; a second delete resumes.
function Remove-ClusterStack([string]$StackName = "kongroo-cluster", [int]$RetryDelaySeconds = 60) {
    foreach ($attempt in 1, 2) {
        Write-Output "Deleting stack $StackName"
        aws cloudformation delete-stack --region $region --stack-name $StackName
        if ($LASTEXITCODE -ne 0) { throw "aws cloudformation delete-stack failed" }
        aws cloudformation wait stack-delete-complete --region $region --stack-name $StackName
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -eq 2) { throw "Stack $StackName did not reach DELETE_COMPLETE: read its events, remove what blocks it, rerun down.ps1" }
        Write-Output "Stack $StackName is DELETE_FAILED; retrying once in $RetryDelaySeconds s"
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Read-CloudEnv {
    if (-not (Test-Path $cloudEnvFile)) {
        throw "$cloudEnvFile not found: fill it by hand with SEARCH_URI, SEARCH_USERNAME and SEARCH_PASSWORD of the Elastic Cloud kongroo-catalog user."
    }
    # Not ConvertFrom-StringData: it unescapes backslashes, which would change a hand-chosen password.
    $values = @{}
    foreach ($line in Get-Content $cloudEnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
    }
    $missing = @("SEARCH_URI", "SEARCH_USERNAME", "SEARCH_PASSWORD" | Where-Object { -not $values[$_] })
    if ($missing) { throw "$cloudEnvFile lacks a value for $($missing -join ', ')" }
    $values
}

function Connect-EksCluster {
    # update-kubeconfig switches to the new context; local scripts expect the previous one.
    $previousContext = kubectl config current-context 2>$null
    try {
        aws eks update-kubeconfig --region $region --name $cluster --alias $kubeContext
        if ($LASTEXITCODE -ne 0) { throw "aws eks update-kubeconfig failed" }
    }
    finally {
        if ($previousContext) {
            kubectl config use-context $previousContext | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not switch the kube context back to $previousContext; it is now $kubeContext. Run: kubectl config use-context $previousContext"
            }
        }
    }
}
