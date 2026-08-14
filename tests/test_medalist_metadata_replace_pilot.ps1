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

$pilotPath = Join-Path $PSScriptRoot "..\experiments\jellyfin12-nfo-refresh\17-medalist-e01-metadata-replace-pilot.ps1"
if (-not (Test-Path -LiteralPath $pilotPath -PathType Leaf)) {
    throw "Pilot not implemented yet: $pilotPath"
}

$text = [System.IO.File]::ReadAllText($pilotPath)

Assert-True ($text -match '\[switch\]\$Apply') "explicit Apply gate"
Assert-True ($text -match '6993f67864a11e1151e7c9c6d3eee68d') "fixed Medalist S02E01 item"
Assert-True ($text -match '1e343af25a95b525ae23adc50142693a') "fixed Medalist series"
Assert-True ($text -match 'ExpectedSeason\s*=\s*2') "expected season preflight"
Assert-True ($text -match 'ExpectedEpisode\s*=\s*1') "expected episode preflight"
Assert-True ($text -match 'Get-TvaNfoSummary') "same-name NFO preflight"
Assert-True ($text -match 'SaveLocalMetadata') "library local-save preflight"
Assert-True ($text -match 'MetadataSavers') "metadata saver preflight"
Assert-True ($text -match 'MetadataFetchers') "remote provider preflight"
Assert-True ($text -match 'LockData') "full metadata lock preflight"
Assert-True ($text -match 'LockedFields') "field lock preflight"
Assert-True ($text -match 'replaceAllMetadata=true') "metadata replacement enabled only for pilot"
Assert-True ($text -match 'imageRefreshMode=None') "images are not refreshed"
Assert-True ($text -match 'replaceAllImages=false') "images are not replaced"
Assert-True ($text -match 'if \(-not \$Apply\)') "dry run exits before POST"
Assert-True ($text -match 'Method Post') "Apply performs one Jellyfin refresh POST"
Assert-True ($text -notmatch 'Method (Delete|Put|Patch)') "no destructive API methods"
Assert-True ($text -notmatch 'Remove-Item|Move-Item|Rename-Item|Set-Content|Out-File') "no media or NFO mutation commands"

# Jellyfin 12 BaseItemDto no longer exposes these observation fields even though
# ItemFields still contains their enum names. The pilot must not wait on them.
Assert-True ($text -notmatch 'DateLastSaved') "do not depend on removed DateLastSaved DTO field"
Assert-True ($text -notmatch 'DateLastRefreshed') "do not depend on removed DateLastRefreshed DTO field"
Assert-True ($text -notmatch 'RefreshState') "do not depend on removed RefreshState DTO field"
Assert-True ($text -notmatch 'Timed out waiting for the Episode metadata refresh to save') "no false timeout on unavailable timestamps"
Assert-True ($text -match 'RESULT: NAME_UNCHANGED_AFTER_OBSERVATION') "bounded unchanged observation result"
Assert-True ($text -match 'refresh completion cannot be proven from BaseItemDto') "explicit observation limitation"

Write-Host "PASS: Medalist metadata replacement pilot safety contract"
