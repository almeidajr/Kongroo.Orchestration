#requires -Version 7
<#
.SYNOPSIS
  Validate the orchestration repo: Kong declarative config parses, kustomize builds,
  and the synced service manifests have no drift.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

Write-Host "kong config parse k8s/kong/kong.yaml"
docker run --rm -e KONG_DATABASE=off `
    -v "$root/k8s/kong/kong.yaml:/kong/declarative/kong.yaml:ro" `
    kong:3.9 kong config parse /kong/declarative/kong.yaml
if ($LASTEXITCODE -ne 0) { throw "kong.yaml failed to parse" }

Write-Host "kubectl kustomize k8s/"
kubectl kustomize "$root/k8s" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "kustomize build failed" }

Write-Host "docker compose config"
docker compose -f "$root/compose.yaml" config --quiet
if ($LASTEXITCODE -ne 0) { throw "compose.yaml failed to validate" }

Write-Host "sync.ps1 -Check"
& "$root/sync.ps1" -Check
exit $LASTEXITCODE
