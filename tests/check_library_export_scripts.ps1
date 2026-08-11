$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$legacyPath = Join-Path $repoRoot "scripts\export_jellyfin_library_10.ps1"
$currentPath = Join-Path $repoRoot "scripts\export_jellyfin_library_12.ps1"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Read-ScriptText {
    param([string]$Path)

    Assert-True (Test-Path -LiteralPath $Path) "Missing script: $Path"
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Assert-CommonContract {
    param(
        [string]$Text,
        [string]$Name
    )

    Assert-True ($Text -match '\[Parameter\(Mandatory\s*=\s*\$true\)\]') "$Name must require ApiKey"
    Assert-True ($Text -match '\[string\]\$ApiKey') "$Name must declare ApiKey"
    Assert-True ($Text -match '\$ErrorActionPreference\s*=\s*["'']Stop["'']') "$Name must fail fast"
    Assert-True ($Text.Contains('Series,Season,Episode,Movie')) "$Name must export the expected item types"
    Assert-True ($Text.Contains('Path,ProviderIds,Overview,PremiereDate,DateCreated,OriginalTitle,SortName')) "$Name must export the expected fields"
    Assert-True ($Text.Contains('/Library/VirtualFolders')) "$Name must export library definitions"
    Assert-True ($Text.Contains('ConvertTo-Json -Depth 20')) "$Name must preserve nested metadata"
    Assert-True (-not ($Text -match '(?i)Remove-Item|Move-Item|Rename-Item|Copy-Item|\-Method\s+(POST|PUT|DELETE|PATCH)')) "$Name must remain read-only"
}

$legacy = Read-ScriptText $legacyPath
$current = Read-ScriptText $currentPath

Assert-CommonContract $legacy "Jellyfin 10 exporter"
Assert-CommonContract $current "Jellyfin 12 exporter"

Assert-True ($legacy.Contains('X-Emby-Token')) "Jellyfin 10 exporter must use X-Emby-Token"
Assert-True (-not $legacy.Contains('MediaBrowser Client=')) "Jellyfin 10 exporter must not use Jellyfin 12 authorization format"

Assert-True ($current.Contains('Authorization')) "Jellyfin 12 exporter must send Authorization header"
Assert-True ($current.Contains('MediaBrowser Client=')) "Jellyfin 12 exporter must use MediaBrowser authorization"
Assert-True (-not $current.Contains('X-Emby-Token')) "Jellyfin 12 exporter must not use legacy token header"

Write-Host "PASS: library export script contract"