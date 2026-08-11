# HISTORICAL / PENDING EXPERIMENT
# Status: NOT YET RUN at creation time.
# Purpose: map which normally-visible Jellyfin Episode owns each hidden
# Fate/strange Fake S01 episode as an alternate/owned media source.
# READ ONLY: this script never refreshes, deletes, merges, or edits metadata.

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
    Authorization = "MediaBrowser Client=`"fate-alternate-diagnose`", Device=`"PowerShell`", DeviceId=`"fate-alternate-diagnose`", Version=`"1.0`", Token=`"$ApiKey`""
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

function Get-AllEpisodes {
    param(
        [switch]$IncludeAlternate
    )

    $startIndex = 0
    $limit = 500
    $allItems = @()

    do {
        $extraQuery = ""
        if ($IncludeAlternate) {
            $extraQuery = "&VideoTypes=VideoFile"
        }

        $uri = "$Server/Items?Recursive=true&StartIndex=$startIndex&Limit=$limit&IncludeItemTypes=Episode&Fields=Path,MediaSources,MediaSourceCount&EnableImages=false&EnableUserData=false$extraQuery"

        $response = Invoke-JellyfinGet -Uri $uri
        $page = @($response.Items)
        $allItems += $page
        $startIndex += $page.Count

    } while ($page.Count -gt 0 -and $startIndex -lt $response.TotalRecordCount)

    return @($allItems)
}

function Get-PathKey {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return $Path.Trim().ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    throw "Refresh log not found: $LogPath"
}

$rows = @(Import-Csv -LiteralPath $LogPath)
$fateRows = @(
    $rows |
    Where-Object {
        $_.Work -eq "Fate/strange Fake"
    } |
    Sort-Object `
        @{ Expression = { [int]$_.TargetSeason } },
        @{ Expression = { [int]$_.TargetEpisode } }
)

if ($fateRows.Count -eq 0) {
    throw "No Fate/strange Fake rows were found in the refresh log."
}

Write-Host ""
Write-Host "=== Fate/strange Fake Alternate Group Diagnosis ==="
Write-Host "Mode: READ ONLY"
Write-Host "Targets: $($fateRows.Count)"
Write-Host ""

Write-Host "Reading normally visible Episode items with media sources..."
$normalEpisodes = @(Get-AllEpisodes)
Write-Host "Normally visible episodes: $($normalEpisodes.Count)"

Write-Host "Reading Episode items including alternate/owned versions..."
$expandedEpisodes = @(Get-AllEpisodes -IncludeAlternate)
Write-Host "Expanded episodes: $($expandedEpisodes.Count)"

$normalById = @{}
$expandedById = @{}
$expandedByPath = @{}

foreach ($item in $normalEpisodes) {
    $normalById[[string]$item.Id] = $item
}

foreach ($item in $expandedEpisodes) {
    $expandedById[[string]$item.Id] = $item

    $pathKey = Get-PathKey -Path ([string]$item.Path)
    if (-not [string]::IsNullOrWhiteSpace($pathKey)) {
        $expandedByPath[$pathKey] = $item
    }
}

$targetByPath = @{}
$targetById = @{}

foreach ($row in $fateRows) {
    $target = "S{0:D2}E{1:D2}" -f [int]$row.TargetSeason, [int]$row.TargetEpisode
    $pathKey = Get-PathKey -Path ([string]$row.VideoPath)
    $itemId = [string]$row.ItemId

    if (-not [string]::IsNullOrWhiteSpace($pathKey)) {
        $targetByPath[$pathKey] = $target
    }

    if (-not [string]::IsNullOrWhiteSpace($itemId)) {
        $targetById[$itemId] = $target
    }
}

# Build a reverse index from every media-source path exposed by a normally
# visible Episode to the visible Episode that owns that source set.
$ownersByTarget = @{}

foreach ($owner in $normalEpisodes) {
    $sources = @($owner.MediaSources)

    foreach ($source in $sources) {
        $sourcePathKey = Get-PathKey -Path ([string]$source.Path)
        if ([string]::IsNullOrWhiteSpace($sourcePathKey)) {
            continue
        }

        if (-not $targetByPath.ContainsKey($sourcePathKey)) {
            continue
        }

        $target = [string]$targetByPath[$sourcePathKey]

        if (-not $ownersByTarget.ContainsKey($target)) {
            $ownersByTarget[$target] = @()
        }

        $ownersByTarget[$target] += [pscustomobject]@{
            OwnerItemId         = [string]$owner.Id
            OwnerSeriesId       = [string]$owner.SeriesId
            OwnerSeriesName     = [string]$owner.SeriesName
            OwnerSeason         = $owner.ParentIndexNumber
            OwnerEpisode        = $owner.IndexNumber
            OwnerSeasonId       = [string]$owner.SeasonId
            OwnerPath           = [string]$owner.Path
            OwnerSourceCount    = $owner.MediaSourceCount
            MatchedSourceId     = [string]$source.Id
            MatchedSourcePath   = [string]$source.Path
        }
    }
}

$summary = @()

foreach ($row in $fateRows) {
    $target = "S{0:D2}E{1:D2}" -f [int]$row.TargetSeason, [int]$row.TargetEpisode
    $itemId = [string]$row.ItemId
    $item = $null

    if (-not [string]::IsNullOrWhiteSpace($itemId) -and $expandedById.ContainsKey($itemId)) {
        $item = $expandedById[$itemId]
    }
    else {
        $pathKey = Get-PathKey -Path ([string]$row.VideoPath)
        if ($expandedByPath.ContainsKey($pathKey)) {
            $item = $expandedByPath[$pathKey]
        }
    }

    $foundNormally = $false
    $foundExpanded = $null -ne $item

    if ($foundExpanded) {
        $foundNormally = $normalById.ContainsKey([string]$item.Id)
    }

    $ownerCandidates = @()
    if ($ownersByTarget.ContainsKey($target)) {
        $ownerCandidates = @($ownersByTarget[$target])
    }

    $summary += [pscustomobject]@{
        Target                  = $target
        ItemId                  = if ($foundExpanded) { [string]$item.Id } else { $itemId }
        FoundNormally           = $foundNormally
        FoundExpanded           = $foundExpanded
        TargetMediaSourceCount  = if ($foundExpanded) { $item.MediaSourceCount } else { $null }
        OwnerCandidates         = $ownerCandidates.Count
    }
}

Write-Host ""
Write-Host "=== Target Summary ==="
Write-Host ""

$summary |
    Format-Table `
        Target,
        ItemId,
        FoundNormally,
        FoundExpanded,
        TargetMediaSourceCount,
        OwnerCandidates `
        -AutoSize

Write-Host ""
Write-Host "=== Target Details ==="

foreach ($row in $fateRows) {
    $target = "S{0:D2}E{1:D2}" -f [int]$row.TargetSeason, [int]$row.TargetEpisode
    $itemId = [string]$row.ItemId
    $item = $null

    if (-not [string]::IsNullOrWhiteSpace($itemId) -and $expandedById.ContainsKey($itemId)) {
        $item = $expandedById[$itemId]
    }
    else {
        $pathKey = Get-PathKey -Path ([string]$row.VideoPath)
        if ($expandedByPath.ContainsKey($pathKey)) {
            $item = $expandedByPath[$pathKey]
        }
    }

    Write-Host ""
    Write-Host "--- $target ---"

    if ($null -eq $item) {
        Write-Host "Target item not found in expanded Episode query."
        continue
    }

    Write-Host "Target ItemId:       $($item.Id)"
    Write-Host "Series:              $($item.SeriesName)"
    Write-Host "SeriesId:            $($item.SeriesId)"
    Write-Host "Season/Episode:      S$($item.ParentIndexNumber)E$($item.IndexNumber)"
    Write-Host "SeasonId:            $($item.SeasonId)"
    Write-Host "MediaSourceCount:    $($item.MediaSourceCount)"
    Write-Host "Target path:         $($item.Path)"

    $targetSources = @($item.MediaSources)

    Write-Host ""
    Write-Host "MediaSources returned for target item: $($targetSources.Count)"

    if ($targetSources.Count -eq 0) {
        Write-Host "(none)"
    }
    else {
        $targetSources |
            Select-Object Id, Name, Path |
            Format-Table -AutoSize
    }

    $ownerCandidates = @()
    if ($ownersByTarget.ContainsKey($target)) {
        $ownerCandidates = @($ownersByTarget[$target])
    }

    Write-Host ""
    Write-Host "Normally-visible owner candidates: $($ownerCandidates.Count)"

    if ($ownerCandidates.Count -eq 0) {
        Write-Host "(none)"
    }
    else {
        $ownerCandidates |
            Sort-Object OwnerItemId -Unique |
            Select-Object `
                OwnerItemId,
                OwnerSeriesName,
                OwnerSeriesId,
                OwnerSeason,
                OwnerEpisode,
                OwnerSeasonId,
                OwnerSourceCount,
                MatchedSourceId,
                OwnerPath |
            Format-List
    }
}

# Print each distinct visible owner only once, together with all media-source
# paths that Jellyfin exposes for that owner.
$distinctOwners = @{}

foreach ($target in $ownersByTarget.Keys) {
    foreach ($candidate in @($ownersByTarget[$target])) {
        $ownerId = [string]$candidate.OwnerItemId
        if (-not [string]::IsNullOrWhiteSpace($ownerId)) {
            $distinctOwners[$ownerId] = $true
        }
    }
}

Write-Host ""
Write-Host "=== Distinct Normally-Visible Owner Groups ==="

if ($distinctOwners.Count -eq 0) {
    Write-Host "(none)"
}
else {
    foreach ($ownerId in ($distinctOwners.Keys | Sort-Object)) {
        if (-not $normalById.ContainsKey($ownerId)) {
            continue
        }

        $owner = $normalById[$ownerId]

        Write-Host ""
        Write-Host "Owner ItemId:        $($owner.Id)"
        Write-Host "Series:              $($owner.SeriesName)"
        Write-Host "SeriesId:            $($owner.SeriesId)"
        Write-Host "Season/Episode:      S$($owner.ParentIndexNumber)E$($owner.IndexNumber)"
        Write-Host "SeasonId:            $($owner.SeasonId)"
        Write-Host "MediaSourceCount:    $($owner.MediaSourceCount)"
        Write-Host "Primary path:        $($owner.Path)"
        Write-Host "MediaSources:"

        $sources = @($owner.MediaSources)

        if ($sources.Count -eq 0) {
            Write-Host "(none)"
        }
        else {
            $sources |
                Select-Object Id, Name, Path |
                Format-Table -AutoSize
        }
    }
}

$hiddenTargets = @($summary | Where-Object { -not $_.FoundNormally -and $_.FoundExpanded })
$hiddenWithOwner = @($hiddenTargets | Where-Object { $_.OwnerCandidates -gt 0 })
$hiddenWithoutOwner = @($hiddenTargets | Where-Object { $_.OwnerCandidates -eq 0 })

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ""
Write-Host "Targets:                         $($summary.Count)"
Write-Host "Hidden alternate/owned targets: $($hiddenTargets.Count)"
Write-Host "Hidden targets with owner:      $($hiddenWithOwner.Count)"
Write-Host "Hidden targets without owner:   $($hiddenWithoutOwner.Count)"
Write-Host "Distinct visible owner items:   $($distinctOwners.Count)"
Write-Host ""
Write-Host "READ ONLY: nothing was changed."
