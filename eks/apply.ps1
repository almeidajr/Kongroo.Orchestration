#requires -Version 7
<#
.SYNOPSIS
  Render the EKS overlay with each API at its ECR image for the repo's origin/master SHA, and apply it to kongroo-eks.
.PARAMETER DryRun
  Print the rendered manifests instead of applying them; needs no cluster.
.PARAMETER Registry
  ECR registry host; defaults to <account>.dkr.ecr.us-east-1.amazonaws.com of the current AWS credentials.
#>
param(
    [switch]$DryRun,
    [string]$Registry
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

if (-not $Registry) {
    $account = aws sts get-caller-identity --query Account --output text
    if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: refresh credentials" }
    $Registry = "$account.dkr.ecr.us-east-1.amazonaws.com"
}

$images = foreach ($name in "Identity", "Catalog", "Payments") {
    $service = $name.ToLowerInvariant()
    $repo = Join-Path (Split-Path $root -Parent) "Kongroo.$name"
    $sha = (git -C $repo ls-remote origin refs/heads/master) -split "\s+" | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch "^[0-9a-f]{40}$") { throw "Cannot resolve origin/master of $repo" }
    "  - name: josealmeidajr/kongroo-$service`n    newName: $Registry/kongroo-$service`n    newTag: `"$sha`""
}

# Outside eks/ (a folder inside it is a kustomize cycle), git-ignored (*.tmp) so no tracked file holds the
# account or SHAs, and unique per run so concurrent runs do not overwrite each other.
$renderDirectory = Join-Path $root "eks-render-$(New-Guid).tmp"
New-Item -ItemType Directory $renderDirectory | Out-Null
try {
    Set-Content "$renderDirectory/kustomization.yaml" "resources:`n  - ../eks`nimages:`n$($images -join "`n")"
    if ($DryRun) { kubectl kustomize $renderDirectory } else { kubectl --context kongroo-eks apply -k $renderDirectory }
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed on the EKS overlay" }
}
finally {
    Remove-Item -Recurse -Force $renderDirectory -ErrorAction SilentlyContinue
}
