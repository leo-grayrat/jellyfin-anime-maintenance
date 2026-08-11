# HISTORICAL / REPAIR EXPERIMENT
# Purpose: split the confirmed 14-source Fate/strange Fake alternate group,
# then refresh only the Fate Series so Jellyfin can create/relink Season 1.
# Default is DRY RUN. -Apply is required for any Jellyfin database changes.
# This script never modifies, deletes, moves, or renames media files or NFO files.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$LogPath = ".\jellyfin_tv_nfo_refresh_log.csv",

    [switch]$Apply,

    [int]$PollIntervalSeconds = 2,

    [int]$SplitTimeoutSeconds = 60,

    [int]$SeriesTimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($PollIntervalSeconds -lt 1) {
    throw "PollIntervalSeconds must be at least 1."
}

$Headers = @{
    Authorization = "MediaBrowser Client=`"fate-alternate-repair`", Device=`"PowerShell`", DeviceId=`"fate-alternate-repair`", Version=`"1.0`", Token=`"$ApiKey`""
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

function Get-ItemById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemId,

        [switch]$IncludeAlternate,

        [switch]$IncludeMediaSources
    )

    $fields = "Path,MediaSourceCount"
    if ($IncludeMediaSources) {
        $fields = "Path,MediaSources,MediaSourceCount"
    }

    $extra = ""
    if ($IncludeAlternate) {
        $extra = "&VideoTypes=VideoFile"
    }

    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&Fields=$fields&EnableImages=false&EnableUserData=false&Limit=10$extra"
    $response = Invoke-JellyfinGet -Uri $uri
    return Get-FirstItem -Response $response
}

function Get-ItemsByIdsNormal {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ItemIds
    )

    $idList = ($ItemIds -join ',')
    $uri = "$Server/Items?Ids=$idList&IncludeItemTypes=Episode&Fields=Path,MediaSourceCount&EnableImages=false&EnableUserData=false&Limit=100"
    $response = Invoke-JellyfinGet -Uri $uri
    return @($response.Items)
}

function Get-SeriesEpisodes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeriesId
    )

    $uri = "$Server/Shows/$SeriesId/Episodes?Fields=Path&EnableImages=false&EnableUserData=false&Limit=500"
    $response = Invoke-JellyfinGet -Uri $uri
    return @($response.Items)
}

function Get-SeriesSeasons {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeriesId
    )

    $uri = "$Server/Shows/$SeriesId/Seasons?Fields=Path&EnableImages=false&EnableUserData=false"
    $response = Invoke-JellyfinGet -Uri $uri
    return @($response.Items)
}

function Invoke-SeriesFullRefresh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeriesId
    )

    $uri = "$Server/Items/$SeriesId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=false&replaceAllImages=false"

    Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $Headers `
        -ErrorAction Stop |
        Out-Null
}

function Test-SameStringSet {
    param(
        [string[]]$A,
        [string[]]$B
    )

    $left = @($A | Sort-Object -Unique)
    $right = @($B | Sort-Object -Unique)

    if ($left.Count -ne $right.Count) {
        return $false
    }

    for ($i = 0; $i -lt $left.Count; $i++) {
        if ($left[$i] -ne $right[$i]) {
            return $false
        }
    }

    return $true
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

if ($fateRows.Count -ne 14) {
    throw "Safety check failed: expected exactly 14 Fate targets, found $($fateRows.Count)."
}

$specialRows = @(
    $fateRows |
    Where-Object {
        [int]$_.TargetSeason -eq 0 -and [int]$_.TargetEpisode -eq 1
    }
)

$s1Rows = @(
    $fateRows |
    Where-Object {
        [int]$_.TargetSeason -eq 1 -and
        [int]$_.TargetEpisode -ge 1 -and
        [int]$_.TargetEpisode -le 13
    }
)

if ($specialRows.Count -ne 1 -or $s1Rows.Count -ne 13) {
    throw "Safety check failed: expected S00E01 plus S01E01-S01E13."
}

$seriesIds = @(
    $fateRows |
    ForEach-Object { [string]$_.SeriesId } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
)

if ($seriesIds.Count -ne 1) {
    throw "Safety check failed: Fate targets do not resolve to exactly one SeriesId."
}

$SeriesId = [string]$seriesIds[0]
$OwnerItemId = [string]$specialRows[0].ItemId
$TargetItemIds = @($fateRows | ForEach-Object { [string]$_.ItemId })

if ([string]::IsNullOrWhiteSpace($OwnerItemId)) {
    throw "Safety check failed: S00E01 ItemId is empty."
}

if (@($TargetItemIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw "Safety check failed: one or more Fate ItemIds are empty."
}

Write-Host ""
Write-Host "=== Fate/strange Fake Alternate Group Repair ==="
Write-Host "Mode: $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
Write-Host "SeriesId: $SeriesId"
Write-Host "Expected owner/primary: S00E01 / $OwnerItemId"
Write-Host "Targets: $($fateRows.Count)"

# Verify every target still exists in the expanded query and already has the
# expected season/episode numbers before changing relationship state.
Write-Host ""
Write-Host "Checking expanded target state..."

foreach ($row in $fateRows) {
    $itemId = [string]$row.ItemId
    $item = Get-ItemById -ItemId $itemId -IncludeAlternate

    if ($null -eq $item) {
        throw "Safety check failed: expanded target not found: $itemId"
    }

    if ([string]$item.SeriesId -ne $SeriesId) {
        throw "Safety check failed: target $itemId has unexpected SeriesId $($item.SeriesId)."
    }

    if ($null -eq $item.ParentIndexNumber -or $null -eq $item.IndexNumber) {
        throw "Safety check failed: target $itemId has empty season/episode numbers."
    }

    if ([int]$item.ParentIndexNumber -ne [int]$row.TargetSeason -or
        [int]$item.IndexNumber -ne [int]$row.TargetEpisode) {
        throw "Safety check failed: target $itemId is not at expected S$($row.TargetSeason)E$($row.TargetEpisode)."
    }
}

Write-Host "Expanded targets: 14/14 present with expected season/episode numbers."

$normalItemsBefore = @(Get-ItemsByIdsNormal -ItemIds $TargetItemIds)
$normalIdsBefore = @($normalItemsBefore | ForEach-Object { [string]$_.Id })

Write-Host "Normally visible targets before repair: $($normalIdsBefore.Count)/14"

$RepairState = "UNKNOWN"

if ($normalIdsBefore.Count -eq 1 -and $normalIdsBefore[0] -eq $OwnerItemId) {
    $owner = Get-ItemById -ItemId $OwnerItemId -IncludeAlternate -IncludeMediaSources

    if ($null -eq $owner) {
        throw "Safety check failed: owner item could not be read."
    }

    $sourceIds = @(
        @($owner.MediaSources) |
        ForEach-Object { [string]$_.Id }
    )

    if ($owner.MediaSourceCount -ne 14) {
        throw "Safety check failed: expected owner MediaSourceCount=14, got $($owner.MediaSourceCount)."
    }

    if (-not (Test-SameStringSet -A $sourceIds -B $TargetItemIds)) {
        throw "Safety check failed: owner's MediaSources are not exactly the 14 Fate target items."
    }

    $RepairState = "GROUPED"
}
elseif ($normalIdsBefore.Count -eq 14 -and (Test-SameStringSet -A $normalIdsBefore -B $TargetItemIds)) {
    $RepairState = "ALREADY_SPLIT"
}
else {
    throw "Safety check failed: unexpected partial relationship state. Normally visible targets: $($normalIdsBefore.Count)/14."
}

$seasonsBefore = @(Get-SeriesSeasons -SeriesId $SeriesId)
$season1Before = @($seasonsBefore | Where-Object { $_.IndexNumber -eq 1 })

Write-Host "Relationship state: $RepairState"
Write-Host "Season 1 objects before repair: $($season1Before.Count)"

if ($season1Before.Count -gt 0) {
    Write-Host "Season 1 already exists; this experiment is no longer needed."
    return
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run passed all safety checks."

    if ($RepairState -eq "GROUPED") {
        Write-Host "Apply would:"
        Write-Host "  1. DELETE /Videos/$OwnerItemId/AlternateSources"
        Write-Host "  2. Verify all 14 target items become normally visible"
        Write-Host "  3. Verify all 14 target items become visible through the Fate Series"
        Write-Host "  4. FullRefresh the Fate Series only"
        Write-Host "  5. Verify Season 1 exists and S01E01-S01E13 link to it"
    }
    else {
        Write-Host "The alternate group is already split. Apply would skip DELETE and continue with Series verification/refresh."
    }

    Write-Host ""
    Write-Host "No Jellyfin data was changed."
    Write-Host "To apply:"
    Write-Host "  .\experiments\jellyfin12-nfo-refresh\07-fate-split-alternate-group.ps1 -ApiKey <API_KEY> -Apply"
    return
}

if ($RepairState -eq "GROUPED") {
    Write-Host ""
    Write-Host "Splitting the confirmed 14-source alternate group..."

    try {
        Invoke-RestMethod `
            -Method Delete `
            -Uri "$Server/Videos/$OwnerItemId/AlternateSources" `
            -Headers $Headers `
            -ErrorAction Stop |
            Out-Null
    }
    catch {
        Write-Host ""
        Write-Host "DELETE request failed. No further refresh will be attempted."
        throw
    }

    Write-Host "AlternateSources DELETE accepted."

    $splitDeadline = (Get-Date).AddSeconds($SplitTimeoutSeconds)
    $normalItemsAfter = @()

    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $normalItemsAfter = @(Get-ItemsByIdsNormal -ItemIds $TargetItemIds)
        Write-Host "Normally visible targets after split: $($normalItemsAfter.Count)/14"

        if ($normalItemsAfter.Count -eq 14) {
            break
        }
    } while ((Get-Date) -lt $splitDeadline)

    $normalIdsAfter = @($normalItemsAfter | ForEach-Object { [string]$_.Id })

    if ($normalItemsAfter.Count -ne 14 -or
        -not (Test-SameStringSet -A $normalIdsAfter -B $TargetItemIds)) {
        Write-Host ""
        Write-Host "PARTIAL FAILURE: alternate group was changed, but all 14 items did not become normally visible."
        Write-Host "Do not rerun the old 243-item batch. Re-run this script without -Apply to inspect the new state."
        return
    }

    Write-Host "All 14 target items are now normally visible."
}
else {
    Write-Host ""
    Write-Host "Alternate group is already split; skipping DELETE."
}

# Before refreshing the Series, require the Series endpoint itself to see all 14
# items. If it cannot, stop: that would mean a second relationship/key problem.
Write-Host ""
Write-Host "Waiting for Fate Series visibility..."

$visibilityDeadline = (Get-Date).AddSeconds($SplitTimeoutSeconds)
$visibleEpisodes = @()
$visibleTargetCount = 0

$targetIdSet = @{}
foreach ($id in $TargetItemIds) {
    $targetIdSet[$id] = $true
}

do {
    $visibleEpisodes = @(Get-SeriesEpisodes -SeriesId $SeriesId)
    $visibleTargetCount = @(
        $visibleEpisodes |
        Where-Object { $targetIdSet.ContainsKey([string]$_.Id) }
    ).Count

    Write-Host "Fate targets visible through Series: $visibleTargetCount/14"

    if ($visibleTargetCount -eq 14) {
        break
    }

    Start-Sleep -Seconds $PollIntervalSeconds
} while ((Get-Date) -lt $visibilityDeadline)

if ($visibleTargetCount -ne 14) {
    Write-Host ""
    Write-Host "PARTIAL FAILURE: alternate group is split, but the Fate Series still cannot see all 14 targets."
    Write-Host "No Series FullRefresh was sent. This indicates another relationship/key issue."
    return
}

Write-Host "All 14 targets are visible through the Fate Series."

Write-Host ""
Write-Host "Refreshing Fate Series metadata..."
Invoke-SeriesFullRefresh -SeriesId $SeriesId
Write-Host "Series FullRefresh queued."

$seriesDeadline = (Get-Date).AddSeconds($SeriesTimeoutSeconds)
$finalSeason = $null
$finalLinkedCount = 0

Write-Host ""
Write-Host "Waiting for Season 1 creation and relink..."

do {
    Start-Sleep -Seconds $PollIntervalSeconds

    $seasons = @(Get-SeriesSeasons -SeriesId $SeriesId)
    $finalSeason = @(
        $seasons |
        Where-Object { $_.IndexNumber -eq 1 }
    ) | Select-Object -First 1

    $episodes = @(Get-SeriesEpisodes -SeriesId $SeriesId)

    if ($null -ne $finalSeason) {
        $seasonId = [string]$finalSeason.Id

        $finalLinkedCount = @(
            $episodes |
            Where-Object {
                [string]$_.SeriesId -eq $SeriesId -and
                $_.ParentIndexNumber -eq 1 -and
                $_.IndexNumber -ge 1 -and
                $_.IndexNumber -le 13 -and
                [string]$_.SeasonId -eq $seasonId
            }
        ).Count
    }
    else {
        $finalLinkedCount = 0
    }

    Write-Host "Season 1: $(if ($null -ne $finalSeason) { 'FOUND' } else { 'missing' }); linked S01 episodes: $finalLinkedCount/13"

    if ($null -ne $finalSeason -and $finalLinkedCount -eq 13) {
        break
    }
} while ((Get-Date) -lt $seriesDeadline)

Write-Host ""
Write-Host "=== Final Result ==="

if ($null -ne $finalSeason -and $finalLinkedCount -eq 13) {
    Write-Host "SUCCESS."
    Write-Host "Season 1 ID: $($finalSeason.Id)"
    Write-Host "All S01E01-S01E13 episodes are linked to Season 1."
    Write-Host "S00E01 remains a separate Specials episode."
}
else {
    Write-Host "PARTIAL FAILURE."
    Write-Host "The alternate group was split, but Season 1 creation/relink did not fully complete."
    Write-Host "Season 1 present: $($null -ne $finalSeason)"
    Write-Host "S01 episodes linked: $finalLinkedCount/13"
    Write-Host "Do not rerun the old 243-item batch. Preserve this output for the next diagnosis."
}
