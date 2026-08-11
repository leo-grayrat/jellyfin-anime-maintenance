# HISTORICAL EXPERIMENT - DO NOT USE AS CURRENT TOOL
# Status: RUN, FAILED with HTTP 400 before refresh.
# Purpose: first attempt to verify Jellyfin 12 episode NFO season refresh.
# Known mistake: GET /Items/{itemId} was used for state reads with an API key.

$ErrorActionPreference = "Stop"

$Server = "http://127.0.0.1:8096"
$ApiKey = "PASTE_API_KEY_HERE"
$ItemId = "4eccd0fc7d467f2d691d88d0822b8d3c"

$Headers = @{
    Authorization = "MediaBrowser Client=`"nfo-refresh-test`", Device=`"PowerShell`", DeviceId=`"nfo-refresh-test`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Get-EpisodeState {
    $Item = Invoke-RestMethod `
        -Method Get `
        -Uri "$Server/Items/$ItemId" `
        -Headers $Headers

    [PSCustomObject]@{
        Name              = $Item.Name
        Path              = $Item.Path
        IndexNumber       = $Item.IndexNumber
        ParentIndexNumber = $Item.ParentIndexNumber
        SeasonName        = $Item.SeasonName
        SeasonId          = $Item.SeasonId
        SeriesName        = $Item.SeriesName
    }
}

Write-Host ""
Write-Host "=== Before FullRefresh ==="
$Before = Get-EpisodeState
$Before | Format-List

Write-Host ""
Write-Host "Requesting FullRefresh..."

$RefreshUri = "$Server/Items/$ItemId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=false&replaceAllImages=false"

Invoke-RestMethod `
    -Method Post `
    -Uri $RefreshUri `
    -Headers $Headers

Write-Host "Refresh request accepted."
Write-Host ""
Write-Host "Waiting for Jellyfin to process the metadata..."

$After = $null

for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 2
    $After = Get-EpisodeState

    Write-Host "Check $i/15 : Season=$($After.ParentIndexNumber), Episode=$($After.IndexNumber)"

    if ($After.ParentIndexNumber -eq 3) {
        break
    }
}

Write-Host ""
Write-Host "=== After FullRefresh ==="
$After | Format-List

Write-Host ""
Write-Host "=== Result ==="

if ($After.ParentIndexNumber -eq 3 -and $After.IndexNumber -eq 7) {
    Write-Host "SUCCESS: Jellyfin changed the episode to S03E07."
}
elseif ($After.ParentIndexNumber -eq $Before.ParentIndexNumber -and $After.IndexNumber -eq $Before.IndexNumber) {
    Write-Host "NO CHANGE: FullRefresh did not change the season."
}
else {
    Write-Host "CHANGED, BUT NOT AS EXPECTED."
}
