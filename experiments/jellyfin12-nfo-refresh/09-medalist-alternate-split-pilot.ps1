# HISTORICAL / DESTRUCTIVE PILOT EXPERIMENT
# Status: NOT YET RUN at creation time.
# Purpose: test Jellyfin's official alternate-source unlink API on one small,
# fully-known wrong group before attempting any global repair.
#
# Target group: Medalist season 2, currently one 8-source group whose members
# already report distinct S02E02..S02E09 numbers.
#
# Default is DRY RUN. -Apply is required for the DELETE request.
# The script never modifies, deletes, moves, or renames media files or NFO files.
# In Apply mode it changes only Jellyfin's alternate-version relationship data.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",

    [switch]$Apply,

    [int]$PollIntervalSeconds = 2,

    [int]$SplitTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($PollIntervalSeconds -lt 1) {
    throw "PollIntervalSeconds must be at least 1."
}

$OwnerId = "af564551c864a8892b28736b0de926de"
$SeriesId = "1e343af25a95b525ae23adc50142693a"

$Headers = @{
    Authorization = "MediaBrowser Client=`"alternate-split-pilot`", Device=`"PowerShell`", DeviceId=`"alternate-split-pilot`", Version=`"1.0`", Token=`"$ApiKey`""
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

function Get-PathKey {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return $Path.Trim().ToLowerInvariant()
}

function Get-EpisodeKey {
    param(
        $Item
    )

    if ($null -eq $Item -or
        $null -eq $Item.ParentIndexNumber -or
        $null -eq $Item.IndexNumber) {
        return ""
    }

    return "S{0:D2}E{1:D2}" -f `
        [int]$Item.ParentIndexNumber,
        [int]$Item.IndexNumber
}

function Get-NormalEpisodes {
    $startIndex = 0
    $limit = 500
    $allItems = @()

    do {
        $uri = "$Server/Items?Recursive=true&StartIndex=$startIndex&Limit=$limit&IncludeItemTypes=Episode&Fields=Path,MediaSources,MediaSourceCount&EnableImages=false&EnableUserData=false"
        $response = Invoke-JellyfinGet -Uri $uri
        $page = @($response.Items)
        $allItems += $page
        $startIndex += $page.Count
    } while ($page.Count -gt 0 -and $startIndex -lt $response.TotalRecordCount)

    return @($allItems)
}

function Get-ExpandedEpisodes {
    $startIndex = 0
    $limit = 500
    $allItems = @()

    do {
        $uri = "$Server/Items?Recursive=true&StartIndex=$startIndex&Limit=$limit&IncludeItemTypes=Episode&VideoTypes=VideoFile&Fields=Path,MediaSources,MediaSourceCount&EnableImages=false&EnableUserData=false"
        $response = Invoke-JellyfinGet -Uri $uri
        $page = @($response.Items)
        $allItems += $page
        $startIndex += $page.Count
    } while ($page.Count -gt 0 -and $startIndex -lt $response.TotalRecordCount)

    return @($allItems)
}

function New-PathMap {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $map = @{}

    foreach ($item in $Items) {
        $key = Get-PathKey -Path ([string]$item.Path)
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $map[$key] = $item
        }
    }

    return $map
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}

Write-Host ""
Write-Host "=== Medalist Alternate Split Pilot ==="
if ($Apply) {
    Write-Host "Mode: APPLY" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: DRY RUN" -ForegroundColor Cyan
}
Write-Host "OwnerId:  $OwnerId"
Write-Host "SeriesId: $SeriesId"
Write-Host ""

$systemInfo = Invoke-JellyfinGet -Uri "$Server/System/Info"
Write-Host "Server version: $($systemInfo.Version)"

$runRows = @(Import-Csv -LiteralPath $RunLogPath)
$targetByPath = @{}

foreach ($row in $runRows) {
    if ([string]$row.RuleId -eq "series-nfo") {
        continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$row.VideoPath) -or
        [string]::IsNullOrWhiteSpace([string]$row.Season) -or
        [string]::IsNullOrWhiteSpace([string]$row.Episode)) {
        continue
    }

    $pathKey = Get-PathKey -Path ([string]$row.VideoPath)
    if ([string]::IsNullOrWhiteSpace($pathKey)) {
        continue
    }

    $expectedKey = "S{0:D2}E{1:D2}" -f [int]$row.Season, [int]$row.Episode

    if ($targetByPath.ContainsKey($pathKey) -and
        [string]$targetByPath[$pathKey] -ne $expectedKey) {
        throw "Conflicting NFO targets exist for one media path."
    }

    $targetByPath[$pathKey] = $expectedKey
}

Write-Host "Reading normal Episode view..."
$normalEpisodes = @(Get-NormalEpisodes)
$normalByPath = New-PathMap -Items $normalEpisodes

$owner = @(
    $normalEpisodes |
    Where-Object {
        [string]$_.Id -eq $OwnerId
    }
) | Select-Object -First 1

if ($null -eq $owner) {
    throw "Pilot owner is not normally visible. Database state changed; aborting."
}

if ([string]$owner.SeriesId -ne $SeriesId) {
    throw "Pilot owner SeriesId changed. Database state changed; aborting."
}

$ownerSources = @($owner.MediaSources)

if ($ownerSources.Count -ne 8) {
    throw "Expected exactly 8 media sources in the pilot group, found $($ownerSources.Count). Database state changed; aborting."
}

Write-Host "Reading expanded Episode view..."
$expandedEpisodes = @(Get-ExpandedEpisodes)
$expandedByPath = New-PathMap -Items $expandedEpisodes

$expectedSet = @{}
foreach ($number in 2..9) {
    $expectedSet[("S02E{0:D2}" -f $number)] = $true
}

$members = @()

foreach ($source in $ownerSources) {
    $pathKey = Get-PathKey -Path ([string]$source.Path)

    if ([string]::IsNullOrWhiteSpace($pathKey)) {
        throw "A pilot media source has no path; aborting."
    }

    if (-not $targetByPath.ContainsKey($pathKey)) {
        throw "A pilot media source is not covered by the NFO correction run log; aborting."
    }

    if (-not $expandedByPath.ContainsKey($pathKey)) {
        throw "A pilot media source cannot be resolved as an expanded Episode; aborting."
    }

    $item = $expandedByPath[$pathKey]
    $expectedKey = [string]$targetByPath[$pathKey]
    $currentKey = Get-EpisodeKey -Item $item

    if (-not $expectedSet.ContainsKey($expectedKey)) {
        throw "Unexpected correction target $expectedKey in pilot group; aborting."
    }

    if ($currentKey -ne $expectedKey) {
        throw "Pilot member $($item.Id) currently reports $currentKey but NFO target is $expectedKey; aborting."
    }

    if ([string]$item.SeriesId -ne $SeriesId) {
        throw "Pilot member $($item.Id) has an unexpected SeriesId; aborting."
    }

    $members += [pscustomobject]@{
        ExpectedKey      = $expectedKey
        CurrentKey       = $currentKey
        ItemId           = [string]$item.Id
        FoundNormally    = $normalByPath.ContainsKey($pathKey)
        MediaSourceCount = $item.MediaSourceCount
        Path             = [string]$item.Path
    }
}

$actualExpectedKeys = @($members.ExpectedKey | Sort-Object -Unique)
if ($actualExpectedKeys.Count -ne 8) {
    throw "Pilot group does not contain 8 distinct expected episode keys; aborting."
}

foreach ($key in $expectedSet.Keys) {
    if ($actualExpectedKeys -notcontains $key) {
        throw "Expected pilot member $key is missing; aborting."
    }
}

Write-Host ""
Write-Host "=== Preflight passed ==="
Write-Host ""

$members |
    Sort-Object ExpectedKey |
    Select-Object ExpectedKey, CurrentKey, ItemId, FoundNormally, MediaSourceCount |
    Format-Table -AutoSize

$hiddenBefore = @($members | Where-Object { -not $_.FoundNormally }).Count
Write-Host "Hidden members before split: $hiddenBefore / 8"
Write-Host "Owner media-source count:    $($ownerSources.Count)"

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN finished."
    Write-Host "No Jellyfin data was changed."
    Write-Host ""
    Write-Host "To run the destructive pilot:"
    Write-Host "  .\experiments\jellyfin12-nfo-refresh\09-medalist-alternate-split-pilot.ps1 -ApiKey <API_KEY> -Apply"
    return
}

Write-Host ""
Write-Host "Deleting only the stale alternate-source relationship for this 8-source group..."

try {
    Invoke-RestMethod `
        -Method Delete `
        -Uri "$Server/Videos/$OwnerId/AlternateSources" `
        -Headers $Headers `
        -ErrorAction Stop |
        Out-Null
}
catch {
    throw "DELETE /Videos/$OwnerId/AlternateSources failed. No further actions were attempted. $($_.Exception.Message)"
}

Write-Host "DELETE request accepted."
Write-Host "Waiting for all eight physical Episodes to become normally visible..."

$deadline = (Get-Date).AddSeconds($SplitTimeoutSeconds)
$afterMembers = @()
$allNormallyVisible = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds

    $normalEpisodes = @(Get-NormalEpisodes)
    $normalByPath = New-PathMap -Items $normalEpisodes
    $afterMembers = @()

    foreach ($before in $members) {
        $pathKey = Get-PathKey -Path ([string]$before.Path)
        $item = $null

        if ($normalByPath.ContainsKey($pathKey)) {
            $item = $normalByPath[$pathKey]
        }

        $afterMembers += [pscustomobject]@{
            ExpectedKey      = $before.ExpectedKey
            ItemIdBefore     = $before.ItemId
            FoundNormally    = $null -ne $item
            ItemIdAfter      = if ($null -ne $item) { [string]$item.Id } else { "" }
            CurrentKey       = if ($null -ne $item) { Get-EpisodeKey -Item $item } else { "" }
            MediaSourceCount = if ($null -ne $item) { $item.MediaSourceCount } else { $null }
            SeasonId         = if ($null -ne $item) { [string]$item.SeasonId } else { "" }
            Path             = $before.Path
        }
    }

    $visibleCount = @($afterMembers | Where-Object { $_.FoundNormally }).Count
    Write-Host "Normally visible after split: $visibleCount / 8"

    if ($visibleCount -eq 8) {
        $allNormallyVisible = $true
        break
    }
}

Write-Host ""
Write-Host "=== After split: normal Episode view ==="
Write-Host ""

$afterMembers |
    Sort-Object ExpectedKey |
    Select-Object ExpectedKey, FoundNormally, CurrentKey, ItemIdAfter, MediaSourceCount, SeasonId |
    Format-Table -AutoSize

if (-not $allNormallyVisible) {
    Write-Host ""
    Write-Host "PARTIAL FAILURE: the alternate group was unlinked, but not all eight items became normally visible before timeout."
    Write-Host "No metadata refresh was attempted. Send this output back for analysis."
    return
}

$badNumberItems = @(
    $afterMembers |
    Where-Object {
        $_.CurrentKey -ne $_.ExpectedKey
    }
)

if ($badNumberItems.Count -gt 0) {
    Write-Host ""
    Write-Host "PARTIAL FAILURE: unlinking exposed all items, but one or more season/episode numbers changed unexpectedly."
    Write-Host "No metadata refresh was attempted. Send this output back for analysis."
    return
}

Write-Host ""
Write-Host "Checking Series-visible Episode list without refreshing the Series..."

$seriesEpisodesUri = "$Server/Shows/$SeriesId/Episodes?Fields=Path,MediaSourceCount&EnableImages=false&EnableUserData=false&Limit=500"
$seriesResponse = Invoke-JellyfinGet -Uri $seriesEpisodesUri
$seriesEpisodes = @($seriesResponse.Items)
$seriesByPath = New-PathMap -Items $seriesEpisodes

$seriesVisible = @()

foreach ($member in $afterMembers) {
    $pathKey = Get-PathKey -Path ([string]$member.Path)
    $item = $null

    if ($seriesByPath.ContainsKey($pathKey)) {
        $item = $seriesByPath[$pathKey]
    }

    $seriesVisible += [pscustomobject]@{
        ExpectedKey   = $member.ExpectedKey
        Visible       = $null -ne $item
        CurrentKey    = if ($null -ne $item) { Get-EpisodeKey -Item $item } else { "" }
        ItemId         = if ($null -ne $item) { [string]$item.Id } else { "" }
        SeasonId       = if ($null -ne $item) { [string]$item.SeasonId } else { "" }
    }
}

Write-Host ""
Write-Host "=== Series-visible state ==="
Write-Host ""

$seriesVisible |
    Sort-Object ExpectedKey |
    Format-Table -AutoSize

$seriesVisibleCount = @($seriesVisible | Where-Object { $_.Visible }).Count
$seriesCorrectCount = @(
    $seriesVisible |
    Where-Object {
        $_.Visible -and $_.CurrentKey -eq $_.ExpectedKey
    }
).Count

Write-Host "Series-visible pilot members: $seriesVisibleCount / 8"
Write-Host "Series-visible with correct S/E: $seriesCorrectCount / 8"
Write-Host ""

if ($seriesVisibleCount -eq 8 -and $seriesCorrectCount -eq 8) {
    Write-Host "SUCCESS: unlinking the stale alternate group was sufficient."
    Write-Host "All eight physical Episodes are now independently visible with their existing correct season/episode numbers."
    Write-Host "No Series FullRefresh was needed in this pilot."
}
else {
    Write-Host "PARTIAL SUCCESS: the stale alternate group was split, but the Series view still needs reconciliation."
    Write-Host "The script intentionally stops here so the next test changes only one variable."
}
