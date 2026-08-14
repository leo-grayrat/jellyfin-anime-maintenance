$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Condition) {
        throw ("{0}: expected true" -f $Label)
    }
}

$scriptPath = Join-Path $PSScriptRoot "..\experiments\jellyfin12-nfo-refresh\18-medalist-e01-post-replace-diagnostic.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Diagnostic not implemented yet: $scriptPath"
}

$text = [System.IO.File]::ReadAllText($scriptPath)

Assert-True ($text -match '6993f67864a11e1151e7c9c6d3eee68d') "fixed Medalist S02E01 item"
Assert-True ($text -match '1e343af25a95b525ae23adc50142693a') "fixed Medalist series"
Assert-True ($text -match '/System/Logs') "server log listing"
Assert-True ($text -match '/System/Logs/Log\?name=') "server log download"
Assert-True ($text -match 'ProviderIds') "provider id inspection"
Assert-True ($text -match 'Overview') "overview inspection"
Assert-True ($text -match 'Medalist - 14') "target path log filter"
Assert-True ($text -notmatch 'Method\s+(Post|Put|Patch|Delete)') "read-only HTTP methods"
Assert-True ($text -notmatch 'Remove-Item|Move-Item|Rename-Item|Set-Content|Out-File|Add-Content') "no local mutation commands"

Write-Host "PASS: Medalist post-replace diagnostic safety contract"
