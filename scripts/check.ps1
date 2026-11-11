#requires -Version 7
<#
.SYNOPSIS
  Validate the orchestration repo: Kong declarative config parses, kustomize builds,
  the CloudFormation templates lint (cfn-lint on PATH), and the synced service manifests have no drift.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

Write-Host "kong config parse k8s/kong/kong.yaml (dummy hex key substituted)"
if (-not (Select-String -Path "$root/k8s/kong/kong.yaml" -Pattern "__JWT_SIGNING_KEY__" -SimpleMatch -Quiet)) {
    throw "kong.yaml must hold the __JWT_SIGNING_KEY__ placeholder, not a key"
}
# Passed as an env var: Windows paths do not bind-mount on every engine, and piped stdin never sees EOF.
docker run --rm -e KONG_DATABASE=off -e JWT_SIGNING_KEY=$('ab' * 32) `
    -e "KONG_YAML=$(Get-Content -Raw "$root/k8s/kong/kong.yaml")" --entrypoint /bin/sh kong:3.9 -c `
    'printf "%s" "$KONG_YAML" | sed "s/__JWT_SIGNING_KEY__/$JWT_SIGNING_KEY/" > /tmp/kong.yaml && kong config parse /tmp/kong.yaml'
if ($LASTEXITCODE -ne 0) { throw "kong.yaml failed to parse" }

Write-Host "kubectl kustomize k8s/"
kubectl kustomize "$root/k8s" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "kustomize build failed" }

Write-Host "docker compose config (throwaway generated env file)"
$envFile = Join-Path $root "check-env.tmp" # git-ignored (*.tmp)
try {
    & "$PSScriptRoot/new-secrets.ps1" -EnvFile $envFile 6>$null
    docker compose -f "$root/compose.yaml" --env-file $envFile config --quiet
    if ($LASTEXITCODE -ne 0) { throw "compose.yaml failed to validate" }
}
finally {
    Remove-Item $envFile -ErrorAction SilentlyContinue
}

Write-Host "cfn-lint eks/*-stack.yaml (with eks/rules)"
cfn-lint --append-rules "$root/eks/rules" -- (Get-ChildItem "$root/eks/*-stack.yaml").FullName
if ($LASTEXITCODE -ne 0) { throw "cfn-lint failed on the eks templates" }

Write-Host "sync.ps1 -Check"
& "$root/sync.ps1" -Check
exit $LASTEXITCODE
