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

$scriptPath = Join-Path $PSScriptRoot "..\experiments\jellyfin12-nfo-refresh\19-medalist-e01-lookup-input-diagnostic.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Diagnostic not implemented yet: $scriptPath"
}

$text = [System.IO.File]::ReadAllText($scriptPath)

Assert-True ($text -match '6993f67864a11e1151e7c9c6d3eee68d') "fixed Medalist S02E01 item"
Assert-True ($text -match '1e343af25a95b525ae23adc50142693a') "fixed Medalist series"
Assert-True ($text -match 'DisplayOrder') "series display order inspection"
Assert-True ($text -match 'PreferredMetadataLanguage') "metadata language inspection"
Assert-True ($text -match 'MetadataCountryCode') "metadata country inspection"
Assert-True ($text -match 'MetadataFetchers') "episode metadata fetcher inspection"
Assert-True ($text -match 'MetadataFetcherOrder') "episode metadata fetcher order inspection"
Assert-True ($text -match 'SeasonId') "season relationship inspection"
Assert-True ($text -match 'SeriesId') "series relationship inspection"
Assert-True ($text -notmatch 'Method\s+(Post|Put|Patch|Delete)') "read-only HTTP methods"
Assert-True ($text -notmatch 'Remove-Item|Move-Item|Rename-Item|Set-Content|Out-File|Add-Content') "no local mutation commands"

Write-Host "PASS: Medalist lookup input diagnostic safety contract"
