#requires -Version 7
<#
.SYNOPSIS
  Arm the four service repos' CI for a cloud day: the Learner Lab session keys as secrets, plus the ECR_REGISTRY and SAM_DEPLOY
  gates that turn on the ECR push, the EKS deploy and sam deploy.
.DESCRIPTION
  Reads the keys pasted into ~/.aws/credentials. Rerun it after every Start Lab press, alone; up.ps1 runs it too.
  Secret values go to gh through stdin and are never printed.
.PARAMETER Disarm
  Delete the same secrets and variables instead (down.ps1), so pushes to master stop at Docker Hub.
.PARAMETER LabStartedAt
  When the Lab timer was last restarted (default: now), recorded in eks/.env for the lab clock that smoke.ps1, seed-games.ps1 and
  watch-release.ps1 print.
#>
param(
    [switch]$Disarm,
    [datetime]$LabStartedAt = (Get-Date)
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"

$account = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: refresh credentials" }

# The names the ci-cd.yml workflows read.
$secretNames = "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"
$registry = "$account.dkr.ecr.us-east-1.amazonaws.com"
$repositories = [ordered]@{
    "almeidajr/Kongroo.Identity"      = @{ ECR_REGISTRY = $registry }
    "almeidajr/Kongroo.Catalog"       = @{ ECR_REGISTRY = $registry }
    "almeidajr/Kongroo.Payments"      = @{ ECR_REGISTRY = $registry }
    "almeidajr/Kongroo.Notifications" = @{ SAM_DEPLOY = "true" }
}

function Assert-Gh([string]$Action) {
    if ($LASTEXITCODE -ne 0) { throw "gh failed to $Action" }
}

if ($Disarm) {
    foreach ($repository in $repositories.GetEnumerator()) {
        # Only what exists, so a rerun after a partial disarm succeeds.
        $existingSecrets = gh secret list --repo $repository.Key --json name --jq ".[].name"
        Assert-Gh "list the secrets of $($repository.Key)"
        foreach ($name in $secretNames | Where-Object { $_ -in $existingSecrets }) {
            gh secret delete $name --repo $repository.Key
            Assert-Gh "delete secret $name on $($repository.Key)"
        }
        $existingVariables = gh variable list --repo $repository.Key --json name --jq ".[].name"
        Assert-Gh "list the variables of $($repository.Key)"
        foreach ($name in $repository.Value.Keys | Where-Object { $_ -in $existingVariables }) {
            gh variable delete $name --repo $repository.Key
            Assert-Gh "delete variable $name on $($repository.Key)"
        }
    }
    Write-Output "CI disarmed: no AWS keys, ECR_REGISTRY or SAM_DEPLOY left on the four service repos."
    return
}

$keys = [ordered]@{}
foreach ($name in $secretNames) {
    $keys[$name] = aws configure get $name.ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or -not $keys[$name]) {
        throw "~/.aws/credentials lacks $($name.ToLowerInvariant()): paste the Learner Lab AWS Details block into [default]"
    }
}

foreach ($repository in $repositories.GetEnumerator()) {
    foreach ($key in $keys.GetEnumerator()) {
        $key.Value | gh secret set $key.Key --repo $repository.Key
        Assert-Gh "set secret $($key.Key) on $($repository.Key)"
    }
    foreach ($variable in $repository.Value.GetEnumerator()) {
        gh variable set $variable.Key --body $variable.Value --repo $repository.Key
        Assert-Gh "set variable $($variable.Key) on $($repository.Key)"
    }
}
# The Learner Lab's session-end sweep disables the Lambda's SQS trigger (CloudTrail: LambdaESMDisabled); the stack survives with it off.
# No output before the first day's stack exists.
$disabledTriggers = aws lambda list-event-source-mappings --region $region --function-name kongroo-notifications `
    --query "EventSourceMappings[?State=='Disabled'].UUID" --output text 2>$null
foreach ($uuid in "$disabledTriggers" -split '\s+' | Where-Object { $_ -and $_ -ne "None" }) {
    aws lambda update-event-source-mapping --region $region --uuid $uuid --enabled --query State --output text | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "aws lambda update-event-source-mapping failed to enable the kongroo-notifications trigger" }
    Write-Output "Re-enabled the kongroo-notifications SQS trigger the lab disabled"
}
Set-LabClock -StartedAt $LabStartedAt
Write-Output "CI armed: session keys on the four service repos, ECR_REGISTRY on the APIs, SAM_DEPLOY=true on Notifications."
