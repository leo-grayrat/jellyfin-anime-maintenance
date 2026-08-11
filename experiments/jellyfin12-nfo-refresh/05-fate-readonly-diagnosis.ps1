# HISTORICAL / PENDING EXPERIMENT
# Status: NOT YET RUN at archive creation time.
# Purpose: read-only diagnosis of why Fate/strange Fake S01E01-S01E13
# have correct ParentIndexNumber but no Season 1 object / SeasonId.
# This script does not refresh items, modify NFO files, or write Jellyfin metadata.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$LogPath = ".\jellyfin_tv_nfo_refresh_log.csv"
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

$Headers = @{
    Authorization = "MediaBrowser Client=`"fate-diagnose`", Device=`"PowerShell`", DeviceId=`"fate-diagnose`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JellyfinGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    return Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $Headers `
        -ErrorAction Stop
}

function Get-FirstItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    return @($Response.Items) | Select-Object -First 1
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Refresh log not found: $LogPath"
}

$Rows = @(Import-Csv -LiteralPath $LogPath)

$FateRows = @(
    $Rows |
    Where-Object {
        $_.Work -eq "Fate/strange Fake"
    }
)

if ($FateRows.Count -eq 0) {
    throw "No Fate/strange Fake rows were found in the refresh log."
}

$SeriesId = [string](
    $FateRows |
    Select-Object -First 1
).SeriesId

if ([string]::IsNullOrWhiteSpace($SeriesId)) {
    throw "Fate SeriesId is missing from the refresh log."
}

Write-Host ""
Write-Host "=== Fate/strange Fake Read-Only Diagnosis ==="
Write-Host ""
Write-Host "SeriesId: $SeriesId"
Write-Host "Targets:  $($FateRows.Count)"

# 1. Read the series itself.
$SeriesUri = "$Server/Items?Ids=$SeriesId&Fields=Path&EnableImages=false&EnableUserData=false&Limit=10"
$SeriesResponse = Invoke-JellyfinGet -Uri $SeriesUri
$Series = Get-FirstItem -Response $SeriesResponse

if ($null -eq $Series) {
    throw "Fate series item was not found."
}

Write-Host ""
Write-Host "=== Series ==="

$Series |
    Select-Object Name, Id, Path, ProviderIds |
    Format-List

# 2. Use the canonical TV Shows season endpoint.
Write-Host ""
Write-Host "=== Seasons visible through the Series ==="

$SeasonsUri = "$Server/Shows/$SeriesId/Seasons?Fields=Path&EnableImages=false&EnableUserData=false"
$SeasonsResponse = Invoke-JellyfinGet -Uri $SeasonsUri
$Seasons = @($SeasonsResponse.Items)

if ($Seasons.Count -eq 0) {
    Write-Host "(none)"
}
else {
    $Seasons |
        Sort-Object IndexNumber |
        Select-Object Name, IndexNumber, Id, LocationType, Path |
        Format-Table -AutoSize
}

# 3. Ask the Series which Episodes it can see.
Write-Host ""
Write-Host "=== Episodes visible through the Series ==="

$VisibleEpisodesUri = "$Server/Shows/$SeriesId/Episodes?Fields=Path&EnableImages=false&EnableUserData=false&Limit=500"
$VisibleEpisodesResponse = Invoke-JellyfinGet -Uri $VisibleEpisodesUri
$VisibleEpisodes = @($VisibleEpisodesResponse.Items)

Write-Host "Visible episode count: $($VisibleEpisodes.Count)"

if ($VisibleEpisodes.Count -gt 0) {
    $VisibleEpisodes |
        Sort-Object ParentIndexNumber, IndexNumber |
        Select-Object IndexNumber, ParentIndexNumber, SeasonName, SeasonId, Id, Path |
        Format-Table -AutoSize
}

$VisibleIds = @{}
foreach ($Episode in $VisibleEpisodes) {
    $VisibleIds[[string]$Episode.Id] = $true
}

# 4. Read every Fate target twice:
#    normal query and expanded query with VideoTypes=VideoFile.
Write-Host ""
Write-Host "=== Direct target diagnosis ==="

$DirectResults = @()

$SortedFateRows =
    $FateRows |
    Sort-Object `
        @{ Expression = { [int]$_.TargetSeason } },
        @{ Expression = { [int]$_.TargetEpisode } }

foreach ($Row in $SortedFateRows) {
    $ItemId = [string]$Row.ItemId

    if ([string]::IsNullOrWhiteSpace($ItemId)) {
        continue
    }

    $NormalUri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&Fields=Path&EnableImages=false&EnableUserData=false&Limit=10"
    $ExpandedUri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&VideoTypes=VideoFile&Fields=Path&EnableImages=false&EnableUserData=false&Limit=10"

    $NormalResponse = Invoke-JellyfinGet -Uri $NormalUri
    $ExpandedResponse = Invoke-JellyfinGet -Uri $ExpandedUri

    $NormalItem = Get-FirstItem -Response $NormalResponse
    $ExpandedItem = Get-FirstItem -Response $ExpandedResponse

    $FoundNormally = $null -ne $NormalItem
    $FoundExpanded = $null -ne $ExpandedItem
    $OwnedOrAlternate = $FoundExpanded -and -not $FoundNormally

    if ($null -ne $ExpandedItem) {
        $Item = $ExpandedItem
    }
    else {
        $Item = $NormalItem
    }

    $Target = "S{0:D2}E{1:D2}" -f [int]$Row.TargetSeason, [int]$Row.TargetEpisode

    if ($null -eq $Item) {
        $DirectResults += [pscustomobject]@{
            Target              = $Target
            Id                  = $ItemId
            FoundNormally       = $false
            FoundExpanded       = $false
            OwnedOrAlternate    = $false
            VisibleInSeries     = $false
            IndexNumber         = $null
            ParentIndexNumber   = $null
            SeasonId            = ""
            SeasonName          = ""
            SeriesId            = ""
            SeriesName          = ""
            Path                = [string]$Row.VideoPath
        }

        continue
    }

    $DirectResults += [pscustomobject]@{
        Target              = $Target
        Id                  = [string]$Item.Id
        FoundNormally       = $FoundNormally
        FoundExpanded       = $FoundExpanded
        OwnedOrAlternate    = $OwnedOrAlternate
        VisibleInSeries     = $VisibleIds.ContainsKey([string]$Item.Id)
        IndexNumber         = $Item.IndexNumber
        ParentIndexNumber   = $Item.ParentIndexNumber
        SeasonId            = [string]$Item.SeasonId
        SeasonName          = [string]$Item.SeasonName
        SeriesId            = [string]$Item.SeriesId
        SeriesName          = [string]$Item.SeriesName
        Path                = [string]$Item.Path
    }
}

$DirectResults |
    Format-Table `
        Target,
        FoundNormally,
        FoundExpanded,
        OwnedOrAlternate,
        VisibleInSeries,
        IndexNumber,
        ParentIndexNumber,
        SeasonId,
        SeriesId `
        -AutoSize

# 5. Print full details.
Write-Host ""
Write-Host "=== Direct target details ==="

$DirectResults | Format-List *

# 6. Check whether the old Season 2026 still exists.
Write-Host ""
Write-Host "=== Old season objects from the refresh log ==="

$OldSeasonIds = @(
    $FateRows |
    ForEach-Object {
        [string]$_.BeforeSeasonId
    } |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } |
    Sort-Object -Unique
)

if ($OldSeasonIds.Count -eq 0) {
    Write-Host "(no old season ids in log)"
}
else {
    foreach ($OldSeasonId in $OldSeasonIds) {
        $OldSeasonUri = "$Server/Items?Ids=$OldSeasonId&IncludeItemTypes=Season&Fields=Path&EnableImages=false&EnableUserData=false&Limit=10"
        $OldSeasonResponse = Invoke-JellyfinGet -Uri $OldSeasonUri
        $OldSeason = Get-FirstItem -Response $OldSeasonResponse

        if ($null -eq $OldSeason) {
            Write-Host ""
            Write-Host "$OldSeasonId : NOT FOUND"
        }
        else {
            Write-Host ""

            $OldSeason |
                Select-Object Name, Id, Type, IndexNumber, SeriesId, LocationType, Path |
                Format-List
        }
    }
}

# 7. Summary.
$DirectMissing = @(
    $DirectResults |
    Where-Object {
        -not $_.FoundExpanded
    }
).Count

$OwnedOrAlternateCount = @(
    $DirectResults |
    Where-Object {
        $_.OwnedOrAlternate
    }
).Count

$InvisibleCount = @(
    $DirectResults |
    Where-Object {
        $_.FoundExpanded -and -not $_.VisibleInSeries
    }
).Count

$WrongSeriesIdCount = @(
    $DirectResults |
    Where-Object {
        $_.FoundExpanded -and
        -not [string]::IsNullOrWhiteSpace($_.SeriesId) -and
        $_.SeriesId -ne $SeriesId
    }
).Count

$EmptySeriesIdCount = @(
    $DirectResults |
    Where-Object {
        $_.FoundExpanded -and
        [string]::IsNullOrWhiteSpace($_.SeriesId)
    }
).Count

$Season1Count = @(
    $Seasons |
    Where-Object {
        $_.IndexNumber -eq 1
    }
).Count

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ""
Write-Host "Direct target items missing:       $DirectMissing"
Write-Host "Owned/alternate target items:      $OwnedOrAlternateCount"
Write-Host "Targets invisible to the Series:   $InvisibleCount"
Write-Host "Targets with wrong SeriesId:       $WrongSeriesIdCount"
Write-Host "Targets with empty SeriesId:       $EmptySeriesIdCount"
Write-Host "Seasons visible through Series:    $($Seasons.Count)"
Write-Host "Season 1 objects visible:          $Season1Count"
Write-Host ""
Write-Host "READ ONLY: nothing was changed."
