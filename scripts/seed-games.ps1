#requires -Version 7
<#
.SYNOPSIS
  Seed the catalog for the search and cache demos: N published games through Kong as admin, plus
  reviews from random customers on the first few (the showcase games), inserted straight into MongoDB.
.DESCRIPTION
  Titles are invented and deterministic (game i is always the same title), so the video's misspelled
  searches always hit. Re-running creates only missing games, publishes only unpublished ones and tops
  showcase games up to -ReviewsPerShowcaseGame, so the result is the same however often it runs.
  Every kubectl call passes -Context; the current kube context is never read or changed.
.PARAMETER Gateway
  Kong proxy base URL. Local k3s: http://localhost:8000. EKS: http://<kong-lb-hostname>.
.PARAMETER AdminPassword
  Bootstrap admin password. Default: BOOTSTRAP_ADMIN_PASSWORD from the .env written by new-secrets.ps1
  (on EKS pass the one in eks/.env).
.PARAMETER Context
  Kube context of the cluster whose MongoDB receives the reviews: rancher-desktop (default) or kongroo-eks.
.EXAMPLE
  ./scripts/seed-games.ps1
  ./scripts/seed-games.ps1 -Gateway http://<kong-lb-hostname> -AdminPassword <from eks/.env> -Context kongroo-eks
#>
param(
    [string]$Gateway = "http://localhost:8000",
    [string]$AdminPassword,
    [string]$Context = "rancher-desktop",
    [string]$AdminUsername = "admin",
    [ValidateRange(1, 1024)][int]$Count = 500,
    [ValidateRange(1, 10)][int]$ShowcaseCount = 4,
    [ValidateRange(0, 5000)][int]$ReviewsPerShowcaseGame = 500
)

$ErrorActionPreference = "Stop"

if (-not $AdminPassword) {
    $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
    if (-not (Test-Path $envFile)) { throw "Not found: $envFile. Run scripts/new-secrets.ps1 first, or pass -AdminPassword." }
    $AdminPassword = (Get-Content -Raw $envFile | ConvertFrom-StringData).BOOTSTRAP_ADMIN_PASSWORD
}

# 32 x 32 invented words; no pair is a real game's name.
$adjectives = @(
    "Amber", "Brass", "Cinder", "Drowsy", "Ember", "Frosted", "Gilded", "Hushed", "Ivory", "Jade", "Kindled",
    "Lunar", "Mossy", "Nimble", "Opal", "Pewter", "Quilted", "Rusted", "Saffron", "Tidal", "Umber", "Velvet",
    "Wistful", "Yonder", "Zephyr", "Copper", "Dusky", "Fabled", "Glassy", "Marbled", "Sunken", "Thistle")
$nouns = @(
    "Lantern", "Orchard", "Foundry", "Harbor", "Meadow", "Citadel", "Burrow", "Canyon", "Lighthouse", "Monastery",
    "Quarry", "Reliquary", "Sawmill", "Tannery", "Vineyard", "Windmill", "Archive", "Bazaar", "Causeway",
    "Dovecote", "Estuary", "Ferry", "Granary", "Hamlet", "Icefield", "Junction", "Kiln", "Loom", "Marsh",
    "Observatory", "Pagoda", "Rookery")
$genres = @("puzzle adventure", "city builder", "roguelike", "rhythm game", "farming sim", "tactics game",
    "platformer", "detective story")

function Get-SeedGame([int]$Index) {
    # Noun index steps by (adjectives + 1), coprime with 32, so titles stay unique and neighbours differ in both words.
    $adjective = $adjectives[$Index % $adjectives.Count]
    $noun = $nouns[([Math]::Floor($Index / $adjectives.Count) + $Index) % $nouns.Count]
    [pscustomobject]@{
        Title       = "$adjective $noun"
        Description = "A $($genres[$Index % $genres.Count]) set around the $($noun.ToLowerInvariant()), where every season leaves the map a little more $($adjective.ToLowerInvariant())."
        PriceAmount = 4.99 + ($Index % 12) * 5
    }
}

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null, [string]$Token)
    $request = @{
        Method = $Method; Uri = "$Gateway$Path"; ContentType = "application/json"
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($null -ne $Body) { $request["Body"] = ($Body | ConvertTo-Json -Compress) }
    Invoke-RestMethod @request
}

$token = (Invoke-RestMethod -Method POST -Uri "$Gateway/identity/tokens" -ContentType "application/json" `
        -Body (@{ username = $AdminUsername; password = $AdminPassword } | ConvertTo-Json -Compress)).accessToken

$seeds = 0..($Count - 1) | ForEach-Object { Get-SeedGame $_ }
$existing = @{}
$catalog = Invoke-Api GET "/catalog/games" -Token $token # assigned first: foreach over the call itself sees one array
foreach ($game in $catalog) { $existing[$game.title] = $game }

Write-Host "Creating games missing from the catalog ($Count seeded titles)" -ForegroundColor Cyan
$created = 0
$games = foreach ($seed in $seeds) {
    if (-not $existing.ContainsKey($seed.Title)) {
        $existing[$seed.Title] = Invoke-Api POST "/catalog/games" @{
            title = $seed.Title; description = $seed.Description; priceAmount = $seed.PriceAmount; currency = "USD"
        } $token
        $created++
    }
    $existing[$seed.Title]
}
Write-Host "$created created, $($Count - $created) already present"

$showcase = $games | Select-Object -First $ShowcaseCount
Write-Host "Topping up reviews to $ReviewsPerShowcaseGame on each showcase game (kubectl --context $Context exec deploy/mongodb)" -ForegroundColor Cyan
$gameIds = ($showcase | ForEach-Object { "'$($_.id)'" }) -join ","
# Single-quoted JS only: the script travels as one argv entry through kubectl and sh.
$script = @"
const target = $ReviewsPerShowcaseGame;
for (const id of [$gameIds]) {
  const gameId = UUID(id);
  const missing = target - db.reviews.countDocuments({ gameId: gameId });
  const docs = [];
  for (let i = 0; i < missing; i++) {
    docs.push({ _id: UUID(), gameId: gameId, customerId: UUID(), customerName: 'Seeded customer ' + i,
      rating: 1 + (i * 7) % 5, text: 'Seeded review ' + i + ': ' + ['loved it', 'solid', 'not for me', 'great value', 'too short'][i % 5],
      createdAt: new Date(Date.now() - i * 60000) });
  }
  if (docs.length > 0) db.reviews.insertMany(docs);
  print(id + ' ' + db.reviews.countDocuments({ gameId: gameId }) + ' reviews');
}
"@
kubectl --context $Context -n kongroo exec deploy/mongodb -- sh -c `
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin kongroo_catalog --eval "$0"' `
    $script
if ($LASTEXITCODE -ne 0) { throw "Inserting reviews into MongoDB failed" }

# Publishing (and re-saving the showcase games) also drops the games cache tag, so no stale reviews read survives the insert.
Write-Host "Publishing seeded games" -ForegroundColor Cyan
$showcaseIds = @($showcase.id)
$published = 0
foreach ($game in $games) {
    if ($game.status -ne "published" -or $showcaseIds -contains $game.id) {
        Invoke-Api PUT "/catalog/games/$($game.id)" @{
            title = $game.title; description = $game.description; priceAmount = $game.priceAmount
            currency = $game.currency; status = "published"
        } $token | Out-Null
        $published++
    }
}
Write-Host "$published updated"

Write-Host "`nShowcase games (k6: -e SHOWCASE=$($showcaseIds -join ','))" -ForegroundColor Green
$showcase | Format-Table id, title
