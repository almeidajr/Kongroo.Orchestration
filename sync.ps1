#requires -Version 7
<#
.SYNOPSIS
  Mirror each Kongroo service repo's hardened k8s/ manifests into this repo's
  k8s/<service>/ directory so Orchestration stays in sync with the services.
.PARAMETER ReposRoot
  Directory containing the sibling Kongroo.* repos. Default: parent of this repo.
.PARAMETER Check
  Sync into a temp dir and compare against the committed k8s/<service>/; exit 1
  if they differ (drift detector). Does not modify the working tree.
#>
param(
    [string]$ReposRoot = "..",
    [switch]$Check
)

$ErrorActionPreference = "Stop"

$services = @(
    @{ Dir = "identity"; Repo = "Kongroo.Identity" },
    @{ Dir = "catalog"; Repo = "Kongroo.Catalog" },
    @{ Dir = "payments"; Repo = "Kongroo.Payments" },
    @{ Dir = "notifications"; Repo = "Kongroo.Notifications" }
)
$copyFiles = @("configmap.yaml", "secret.yaml", "service.yaml", "deployment.yaml")

$reposBase = (Resolve-Path (Join-Path $PSScriptRoot $ReposRoot)).Path
$k8sRoot = Join-Path $PSScriptRoot "k8s"

function Sync-Service {
    param([hashtable]$Service, [string]$DestRoot)

    $src = Join-Path $reposBase (Join-Path $Service.Repo "k8s")
    if (-not (Test-Path $src)) { throw "Source manifests not found: $src" }

    $dest = Join-Path $DestRoot $Service.Dir
    if (Test-Path $dest) {
        Get-ChildItem -Path $dest -Force | Remove-Item -Recurse -Force
    }
    else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }

    foreach ($file in $copyFiles) {
        $from = Join-Path $src $file
        if (-not (Test-Path $from)) { throw "Missing $from" }
        Copy-Item $from (Join-Path $dest $file) -Force
    }

    # Copy kustomization.yaml minus the namespace field and the namespace.yaml
    # resource (the namespace is owned once by the top-level kustomization).
    $srcKust = Join-Path $src "kustomization.yaml"
    if (-not (Test-Path $srcKust)) { throw "Missing $srcKust" }
    $filtered = Get-Content $srcKust | Where-Object {
        ($_ -notmatch '^\s*-\s*namespace\.yaml\s*$') -and
        ($_ -notmatch '^\s*namespace:\s*kongroo\s*$')
    }
    Set-Content -Path (Join-Path $dest "kustomization.yaml") -Value $filtered
}

if ($Check) {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("kongroo-sync-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $drift = @()
        foreach ($svc in $services) {
            Sync-Service -Service $svc -DestRoot $temp
            $committed = Join-Path $k8sRoot $svc.Dir
            $fresh = Join-Path $temp $svc.Dir
            $freshNames = Get-ChildItem $fresh -File | Select-Object -ExpandProperty Name
            $committedNames = if (Test-Path $committed) { Get-ChildItem $committed -File | Select-Object -ExpandProperty Name } else { @() }
            foreach ($n in ($freshNames + $committedNames | Sort-Object -Unique)) {
                $a = Join-Path $committed $n
                $b = Join-Path $fresh $n
                if (-not (Test-Path $a) -or -not (Test-Path $b)) {
                    $drift += "$($svc.Dir)/$n (present in only one side)"
                }
                elseif ((Get-FileHash $a).Hash -ne (Get-FileHash $b).Hash) {
                    $drift += "$($svc.Dir)/$n (content differs)"
                }
            }
        }
        if ($drift.Count -gt 0) {
            Write-Host "Drift detected (run ./sync.ps1 to fix):" -ForegroundColor Red
            $drift | ForEach-Object { Write-Host "  $_" }
            exit 1
        }
        Write-Host "In sync - no drift." -ForegroundColor Green
        exit 0
    }
    finally {
        Remove-Item $temp -Recurse -Force
    }
}
else {
    foreach ($svc in $services) {
        Sync-Service -Service $svc -DestRoot $k8sRoot
        Write-Host "Synced k8s/$($svc.Dir) from $($svc.Repo)"
    }
    Write-Host "Done. Review changes, then: kubectl apply -k k8s/"
}
