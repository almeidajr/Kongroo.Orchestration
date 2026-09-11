#requires -Version 7
<#
.SYNOPSIS
  Drive the FIAP Cloud Games flows through the Kong gateway: register, login, create and
  publish a game as admin, buy it as the player, and watch the order settle.
.PARAMETER Gateway
  Kong proxy base URL. http://localhost:8000 (default) serves both compose and k8s; run one mode at a time.
.PARAMETER AdminUsername
  Bootstrap admin username. Compose: developer (default). Kubernetes: admin
#>
param(
    [string]$Gateway = "http://localhost:8000",
    [string]$AdminUsername = "developer",
    [string]$AdminPassword = "Sup3rSecure!"
)

$ErrorActionPreference = "Stop"
$suffix = Get-Date -Format "HHmmss"

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null, [string]$Token = $null)
    $headers = @{}
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }
    $request = @{ Method = $Method; Uri = "$Gateway$Path"; Headers = $headers; ContentType = "application/json" }
    if ($null -ne $Body) { $request["Body"] = ($Body | ConvertTo-Json -Compress) }
    Invoke-RestMethod @request
}

Write-Host "`n[1] Anonymous call is rejected at the gateway" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$Gateway/catalog/games" | Out-Null
    throw "Expected 401 from Kong"
}
catch [Microsoft.PowerShell.Commands.HttpResponseException] {
    if ([int]$_.Exception.Response.StatusCode -ne 401) { throw }
    Write-Host "Kong answered 401 Unauthorized"
}

Write-Host "`n[2] Register player$suffix (POST /identity/users, no token)" -ForegroundColor Cyan
$player = Invoke-Api POST "/identity/users" @{
    username = "player$suffix"; email = "player$suffix@kongroo.dev"; password = "Play3r!Pass"; name = "Player $suffix"
}
$player | Format-List id, username, email

Write-Host "`n[3] Login as player and as admin (POST /identity/tokens)" -ForegroundColor Cyan
$playerToken = (Invoke-Api POST "/identity/tokens" @{ username = "player$suffix"; password = "Play3r!Pass" }).accessToken
$adminToken = (Invoke-Api POST "/identity/tokens" @{ username = $AdminUsername; password = $AdminPassword }).accessToken
Write-Host "Player token: $($playerToken.Substring(0, 24))..."

Write-Host "`n[4] Admin creates and publishes a game (POST/PUT /catalog/games)" -ForegroundColor Cyan
$game = Invoke-Api POST "/catalog/games" @{
    title = "Portal $suffix"; description = "A puzzle platformer."; priceAmount = 19.99; currency = "USD"
} $adminToken
Invoke-Api PUT "/catalog/games/$($game.id)" @{
    title = $game.title; description = $game.description; priceAmount = 19.99; currency = "USD"; status = "published"
} $adminToken | Out-Null
Write-Host "Game $($game.id) published"

Write-Host "`n[5] Player buys the game (POST /catalog/orders)" -ForegroundColor Cyan
$order = Invoke-Api POST "/catalog/orders" @{ gameIds = @($game.id) } $playerToken
Write-Host "Order $($order.id) status: $($order.status)"

Write-Host "`n[6] Wait for Payments to settle the order" -ForegroundColor Cyan
$current = $order
for ($attempt = 0; $attempt -lt 30 -and $current.status -eq "pending"; $attempt++) {
    Start-Sleep -Seconds 1
    $current = Invoke-Api GET "/catalog/orders/$($order.id)" -Token $playerToken
}
Write-Host "Order $($order.id) status: $($current.status)"

Write-Host "`n[7] Library and payment record" -ForegroundColor Cyan
Invoke-Api GET "/catalog/ownerships" -Token $playerToken | Format-Table gameId, orderId, acquiredAt
Invoke-Api GET "/payments/$($order.id)" -Token $playerToken | Format-List
