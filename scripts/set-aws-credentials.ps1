#requires -Version 7
<#
.SYNOPSIS
  Copy the AWS Academy Learner Lab session credentials into the aws-credentials
  Secret and restart the API deployments that talk to SQS/SNS.
.DESCRIPTION
  In the Learner Lab click "AWS Details" -> "AWS CLI" -> "Show" and paste the block into
  ~/.aws/credentials (it is a [default] profile with aws_session_token). Then run this script.
.PARAMETER Profile
  Profile name inside ~/.aws/credentials. Default: default.
.PARAMETER Namespace
  Kubernetes namespace. Default: kongroo.
#>
param(
    [string]$Profile = "default",
    [string]$Namespace = "kongroo"
)

$ErrorActionPreference = "Stop"

$credentialsPath = Join-Path $HOME ".aws" "credentials"
if (-not (Test-Path $credentialsPath)) { throw "Not found: $credentialsPath. Paste the Learner Lab credentials there first." }

$lines = Get-Content $credentialsPath
$start = [Array]::IndexOf($lines, "[$Profile]")
if ($start -lt 0) { throw "Profile [$Profile] not found in $credentialsPath." }

$section = @{}
foreach ($line in $lines[($start + 1)..($lines.Length - 1)]) {
    if ($line -match '^\s*\[') { break }
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$') { $section[$Matches[1]] = $Matches[2] }
}

foreach ($key in "aws_access_key_id", "aws_secret_access_key", "aws_session_token") {
    if (-not $section.ContainsKey($key)) { throw "Profile [$Profile] is missing $key (Learner Lab credentials always include a session token)." }
}

kubectl -n $Namespace create secret generic aws-credentials `
    --from-literal=AWS_ACCESS_KEY_ID=$($section.aws_access_key_id) `
    --from-literal=AWS_SECRET_ACCESS_KEY=$($section.aws_secret_access_key) `
    --from-literal=AWS_SESSION_TOKEN=$($section.aws_session_token) `
    --dry-run=client -o yaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed." }

foreach ($deployment in "identity-api", "catalog-api", "payments-api") {
    kubectl -n $Namespace rollout restart deployment/$deployment
    if ($LASTEXITCODE -ne 0) { throw "rollout restart of deployment/$deployment failed." }
}

Write-Host "aws-credentials updated from profile [$Profile]; API deployments restarting." -ForegroundColor Green
