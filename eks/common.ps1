# Dot-sourced by up.ps1, down.ps1, smoke.ps1 and scripts/new-secrets.ps1 -Target Eks.
$region = "us-east-1"
$cluster = "kongroo"
$kubeContext = "kongroo-eks"
$cloudEnvFile = Join-Path $PSScriptRoot "cloud.env"

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
