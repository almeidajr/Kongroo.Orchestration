#requires -Version 7
<#
.SYNOPSIS
  Watch a live Catalog deploy through Kong: one GET /catalog/games/{id} a second, printing
  "HH:mm:ss <status> <x-kongroo-release header>", until Ctrl+C.
.DESCRIPTION
  Logs in as a player (registered on first use) and logs in again every 10 minutes, well inside the
  15-minute JWT lifetime, so a token expiry never prints a 401 that looks like downtime. A request that
  gets no HTTP answer at all prints ERR with the reason.
.PARAMETER Gateway
  Kong proxy base URL. Local k3s: http://localhost:8000. EKS: http://<kong-lb-hostname>.
.PARAMETER GameId
  Game to request. Default: the first game GET /catalog/games returns.
#>
param(
    [string]$Gateway = "http://localhost:8000",
    [string]$Username = "release-watcher",
    [string]$Password = "W4tch!Release",
    [string]$GameId
)

$ErrorActionPreference = "Stop"
$reloginAfter = [TimeSpan]::FromMinutes(10)
. (Join-Path (Split-Path $PSScriptRoot -Parent) "eks/common.ps1")
Write-LabClock

function Get-Token {
    $body = @{ username = $Username; password = $Password } | ConvertTo-Json -Compress
    (Invoke-RestMethod -Method POST -Uri "$Gateway/identity/tokens" -ContentType "application/json" -Body $body).accessToken
}

# Registration answers an error once the player exists; the login below is what must succeed.
$registration = @{ username = $Username; email = "$Username@kongroo.dev"; password = $Password; name = "Release Watcher" }
Invoke-WebRequest -Method POST -Uri "$Gateway/identity/users" -ContentType "application/json" -SkipHttpErrorCheck `
    -Body ($registration | ConvertTo-Json -Compress) | Out-Null

$token = Get-Token
$loggedInAt = Get-Date
if (-not $GameId) {
    $GameId = (Invoke-RestMethod -Uri "$Gateway/catalog/games" -Headers @{ Authorization = "Bearer $token" })[0].id
}
Write-Host "Watching GET $Gateway/catalog/games/$GameId as $Username (Ctrl+C to stop)"

while ($true) {
    $startedAt = Get-Date
    if ($startedAt - $loggedInAt -ge $reloginAfter) {
        try { $token = Get-Token; $loggedInAt = $startedAt }
        catch { Write-Host ("{0:HH:mm:ss} login failed, retrying next second: {1}" -f $startedAt, $_.Exception.Message) }
    }
    try {
        $response = Invoke-WebRequest -Uri "$Gateway/catalog/games/$GameId" -Headers @{ Authorization = "Bearer $token" } `
            -SkipHttpErrorCheck -TimeoutSec 5
        Write-Host ("{0:HH:mm:ss} {1} {2}" -f $startedAt, $response.StatusCode, ($response.Headers["x-kongroo-release"] -join ","))
    }
    catch {
        Write-Host ("{0:HH:mm:ss} ERR {1}" -f $startedAt, $_.Exception.Message)
    }
    $remaining = 1000 - ((Get-Date) - $startedAt).TotalMilliseconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
}
