# HISTORICAL EXPERIMENT - DO NOT USE AS CURRENT TOOL
# Status: RUN, SUCCESS.
# Purpose: verify that Series FullRefresh relinks an episode whose
# ParentIndexNumber has already been corrected by its NFO.
# Result: SPY x FAMILY S03E07 SeasonId moved from Season 1 to Season 3.

$ErrorActionPreference = "Stop"

$Server = "http://127.0.0.1:8096"
$ApiKey = "PASTE_API_KEY_HERE"
$EpisodeId = "4eccd0fc7d467f2d691d88d0822b8d3c"

$Headers = @{
    Authorization = "MediaBrowser Client=`"season-relink-test`", Device=`"PowerShell`", DeviceId=`"season-relink-test`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Get-EpisodeState {
    $Uri = "$Server/Items?Ids=$EpisodeId&Recursive=true&Limit=1&Fields=Path,ProviderIds&EnableImages=false&EnableUserData=false"

    $Response = Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $Headers

    if ($Response.Items.Count -eq 0) {
        throw "Target episode was not found."
    }

    $Item = $Response.Items[0]

    return [PSCustomObject]@{
        Name              = $Item.Name
        Path              = $Item.Path
        IndexNumber       = $Item.IndexNumber
        ParentIndexNumber = $Item.ParentIndexNumber
        SeasonName        = $Item.SeasonName
        SeasonId          = $Item.SeasonId
        SeriesName        = $Item.SeriesName
        SeriesId          = $Item.SeriesId
    }
}

Write-Host ""
Write-Host "=== Current Episode State ==="

$Before = Get-EpisodeState
$Before | Format-List

if ($Before.ParentIndexNumber -ne 3) {
    Write-Host ""
    Write-Host "Episode season number is not 3 yet."
    Write-Host "Running Episode FullRefresh first..."

    $EpisodeRefreshUri = "$Server/Items/$EpisodeId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=false&replaceAllImages=false"

    Invoke-RestMethod `
        -Method Post `
        -Uri $EpisodeRefreshUri `
        -Headers $Headers

    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2
        $State = Get-EpisodeState

        Write-Host "Episode check $i/15 : Season=$($State.ParentIndexNumber), Episode=$($State.IndexNumber)"

        if ($State.ParentIndexNumber -eq 3) {
            break
        }
    }

    $Before = Get-EpisodeState
}

if ($Before.ParentIndexNumber -ne 3) {
    throw "Episode FullRefresh did not change ParentIndexNumber to 3."
}

$SeriesId = $Before.SeriesId

Write-Host ""
Write-Host "Series:"
Write-Host "$($Before.SeriesName)"
Write-Host "SeriesId: $SeriesId"

Write-Host ""
Write-Host "Looking for Season 3..."

$SeasonUri = "$Server/Items?ParentId=$SeriesId&IncludeItemTypes=Season&Recursive=false&Limit=100&EnableImages=false&EnableUserData=false"

$SeasonResponse = Invoke-RestMethod `
    -Method Get `
    -Uri $SeasonUri `
    -Headers $Headers

$Season3 = $SeasonResponse.Items |
    Where-Object { $_.IndexNumber -eq 3 } |
    Select-Object -First 1

if ($null -eq $Season3) {
    throw "Season 3 object was not found."
}

$ExpectedSeasonId = $Season3.Id

Write-Host "Season 3 found."
Write-Host "Season 3 name: $($Season3.Name)"
Write-Host "Season 3 ID:   $ExpectedSeasonId"

Write-Host ""
Write-Host "=== Refreshing Series ==="

$SeriesRefreshUri = "$Server/Items/$SeriesId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=false&replaceAllImages=false"

Invoke-RestMethod `
    -Method Post `
    -Uri $SeriesRefreshUri `
    -Headers $Headers

Write-Host "Series refresh request accepted."
Write-Host ""
Write-Host "Waiting for season reconciliation..."

$After = $null

for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    $After = Get-EpisodeState

    Write-Host (
        "Check $i/30 : " +
        "ParentSeason=$($After.ParentIndexNumber), " +
        "SeasonName=$($After.SeasonName), " +
        "SeasonId=$($After.SeasonId)"
    )

    if ($After.SeasonId -eq $ExpectedSeasonId) {
        break
    }
}

Write-Host ""
Write-Host "=== Final Episode State ==="
$After | Format-List

Write-Host ""
Write-Host "=== Result ==="

if ($After.ParentIndexNumber -eq 3 -and $After.SeasonId -eq $ExpectedSeasonId) {
    Write-Host "SUCCESS."
    Write-Host "Episode is now fully linked to Season 3."
}
elseif ($After.ParentIndexNumber -eq 3 -and $After.SeasonId -ne $ExpectedSeasonId) {
    Write-Host "PARTIAL FAILURE."
    Write-Host "ParentIndexNumber is 3, but SeasonId was not reconciled."
}
else {
    Write-Host "UNEXPECTED RESULT."
    Write-Host "Please send the complete output for analysis."
}
