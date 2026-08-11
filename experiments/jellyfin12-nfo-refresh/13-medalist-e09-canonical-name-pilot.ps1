# MEDALIST S02E09 CANONICAL-NAME PILOT
#
# Goal: test one variable only. Remove Medalist S02E09 from Jellyfin, then add
# the same video + NFO back with an explicit "S02E09 - " filename prefix.
# If it stays independent, the filename parser (not stale DB state alone) is
# the practical cause of the bad LocalAlternateVersion grouping.
#
# Default: DRY RUN. -Apply is required.
# No SQLite writes, no metadata refresh, no other episode files are touched.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",
    [string]$StagingRoot = "",
    [switch]$Apply,
    [int]$PollIntervalSeconds = 2,
    [int]$RemovalTimeoutSeconds = 180,
    [int]$ReaddTimeoutSeconds = 180,
    [int]$StableSamples = 5
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($PollIntervalSeconds -lt 1) { throw "PollIntervalSeconds must be at least 1." }
if ($RemovalTimeoutSeconds -lt 10) { throw "RemovalTimeoutSeconds must be at least 10." }
if ($ReaddTimeoutSeconds -lt 10) { throw "ReaddTimeoutSeconds must be at least 10." }
if ($StableSamples -lt 2) { throw "StableSamples must be at least 2." }

$OwnerId = "af564551c864a8892b28736b0de926de"
$OldTargetId = "59a625fe5a7b8584017e2707eea78cd3"
$SeriesId = "1e343af25a95b525ae23adc50142693a"
$ExpectedOwnerKey = "S02E02"
$ExpectedTargetKey = "S02E09"
$CanonicalPrefix = "S02E09 - "

$Headers = @{
    Authorization = "MediaBrowser Client=`"canonical-name-pilot`", Device=`"PowerShell`", DeviceId=`"canonical-name-pilot`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/').ToLowerInvariant()
}

function Test-InsideRoot {
    param([string]$Path, [string]$Root)
    $p = (Get-PathKey -Path $Path)
    $r = (Get-PathKey -Path $Root)
    if ($p -eq $r) { return $true }
    return $p.StartsWith($r + "\")
}

function Get-EpisodeKey {
    param($Item)
    if ($null -eq $Item -or $null -eq $Item.ParentIndexNumber -or $null -eq $Item.IndexNumber) {
        return ""
    }
    return "S{0:D2}E{1:D2}" -f [int]$Item.ParentIndexNumber, [int]$Item.IndexNumber
}

function Get-EpisodeById {
    param([string]$ItemId, [switch]$Expanded)
    $fields = [uri]::EscapeDataString("Path,MediaSources,MediaSourceCount,SeriesId,SeasonId")
    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&Fields=$fields&EnableImages=false&EnableUserData=false"
    if ($Expanded) { $uri += "&VideoTypes=VideoFile" }
    $response = Invoke-JfGet -Uri $uri
    $items = @($response.Items)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Get-AllEpisodes {
    param([switch]$Expanded)
    $start = 0
    $limit = 500
    $all = @()
    $fields = [uri]::EscapeDataString("Path,MediaSources,MediaSourceCount,SeriesId,SeasonId")
    do {
        $uri = "$Server/Items?Recursive=true&StartIndex=$start&Limit=$limit&IncludeItemTypes=Episode&Fields=$fields&EnableImages=false&EnableUserData=false"
        if ($Expanded) { $uri += "&VideoTypes=VideoFile" }
        $response = Invoke-JfGet -Uri $uri
        $page = @($response.Items)
        $all += $page
        $start += $page.Count
    } while ($page.Count -gt 0 -and $start -lt $response.TotalRecordCount)
    return @($all)
}

function Get-EpisodeByPath {
    param([string]$Path, [switch]$Expanded)
    $wanted = Get-PathKey -Path $Path
    $items = if ($Expanded) { @(Get-AllEpisodes -Expanded) } else { @(Get-AllEpisodes) }
    foreach ($item in $items) {
        if ((Get-PathKey -Path ([string]$item.Path)) -eq $wanted) { return $item }
    }
    return $null
}

function Get-OwnerState {
    param([string]$ObservedPath)
    $owner = Get-EpisodeById -ItemId $OwnerId
    if ($null -eq $owner) {
        return [pscustomobject]@{ Found = $false; SourceCount = -1; ContainsPath = $false }
    }
    $wanted = Get-PathKey -Path $ObservedPath
    $contains = $false
    foreach ($source in @($owner.MediaSources)) {
        if ((Get-PathKey -Path ([string]$source.Path)) -eq $wanted) { $contains = $true; break }
    }
    return [pscustomobject]@{ Found = $true; SourceCount = @($owner.MediaSources).Count; ContainsPath = $contains }
}

function Get-ObservedState {
    param([string]$Path)
    $normal = Get-EpisodeByPath -Path $Path
    $expanded = Get-EpisodeByPath -Path $Path -Expanded
    $ownerState = Get-OwnerState -ObservedPath $Path
    return [pscustomobject]@{
        OwnerSourceCount = $ownerState.SourceCount
        OwnerContainsTarget = $ownerState.ContainsPath
        TargetNormal = ($null -ne $normal)
        TargetExpanded = ($null -ne $expanded)
        TargetId = if ($null -ne $expanded) { [string]$expanded.Id } else { "" }
        TargetKey = if ($null -ne $expanded) { Get-EpisodeKey -Item $expanded } else { "" }
        TargetMediaSources = if ($null -ne $expanded) { @($expanded.MediaSources).Count } else { 0 }
        TargetSeriesId = if ($null -ne $expanded) { [string]$expanded.SeriesId } else { "" }
        TargetSeasonId = if ($null -ne $expanded) { [string]$expanded.SeasonId } else { "" }
    }
}

function Get-StateSignature {
    param($State)
    return "owner={0};ownerHasPath={1};normal={2};expanded={3};id={4};key={5};sources={6};series={7};season={8}" -f `
        $State.OwnerSourceCount, $State.OwnerContainsTarget, $State.TargetNormal, $State.TargetExpanded, `
        $State.TargetId, $State.TargetKey, $State.TargetMediaSources, $State.TargetSeriesId, $State.TargetSeasonId
}

function Get-SeriesVisible {
    param([string]$Path)
    $wanted = Get-PathKey -Path $Path
    $fields = [uri]::EscapeDataString("Path")
    $response = Invoke-JfGet -Uri "$Server/Shows/$SeriesId/Episodes?Fields=$fields&EnableImages=false&EnableUserData=false&Limit=500"
    foreach ($item in @($response.Items)) {
        if ((Get-PathKey -Path ([string]$item.Path)) -eq $wanted) { return $true }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}

Write-Host ""
Write-Host "=== Medalist S02E09 Canonical-name Pilot ==="
if ($Apply) { Write-Host "Mode: APPLY" -ForegroundColor Yellow } else { Write-Host "Mode: DRY RUN" -ForegroundColor Cyan }
Write-Host "OwnerId:     $OwnerId ($ExpectedOwnerKey)"
Write-Host "OldTargetId: $OldTargetId ($ExpectedTargetKey)"
Write-Host "SeriesId:    $SeriesId"
Write-Host ""

$info = Invoke-JfGet -Uri "$Server/System/Info"
Write-Host "Server version: $($info.Version)"

$owner = Get-EpisodeById -ItemId $OwnerId
$oldNormal = Get-EpisodeById -ItemId $OldTargetId
$oldExpanded = Get-EpisodeById -ItemId $OldTargetId -Expanded

if ($null -eq $owner) { throw "Owner is not normally visible; aborting." }
if ([string]$owner.SeriesId -ne $SeriesId) { throw "Owner SeriesId changed; aborting." }
if ((Get-EpisodeKey -Item $owner) -ne $ExpectedOwnerKey) { throw "Owner no longer reports S02E02; aborting." }
if (@($owner.MediaSources).Count -ne 8) { throw "Expected 8 owner media sources; found $(@($owner.MediaSources).Count)." }
if ($null -ne $oldNormal) { throw "Old target is already normally visible; aborting." }
if ($null -eq $oldExpanded) { throw "Old target is not visible in expanded view; aborting." }
if ((Get-EpisodeKey -Item $oldExpanded) -ne $ExpectedTargetKey) { throw "Old target no longer reports S02E09; aborting." }
if ([string]$oldExpanded.SeriesId -ne $SeriesId) { throw "Old target SeriesId changed; aborting." }

$originalVideo = [System.IO.Path]::GetFullPath([string]$oldExpanded.Path)
$originalNfo = [System.IO.Path]::ChangeExtension($originalVideo, ".nfo")
if (-not (Test-Path -LiteralPath $originalVideo -PathType Leaf)) { throw "Video not found: $originalVideo" }
if (-not (Test-Path -LiteralPath $originalNfo -PathType Leaf)) { throw "NFO not found: $originalNfo" }

$oldPathKey = Get-PathKey -Path $originalVideo
$ownerHasOldPath = $false
foreach ($source in @($owner.MediaSources)) {
    if ((Get-PathKey -Path ([string]$source.Path)) -eq $oldPathKey) { $ownerHasOldPath = $true; break }
}
if (-not $ownerHasOldPath) { throw "Owner does not contain the expected S02E09 path; aborting." }

$logMatch = @(
    Import-Csv -LiteralPath $RunLogPath |
    Where-Object {
        [string]$_.RuleId -ne "series-nfo" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.VideoPath) -and
        (Get-PathKey -Path ([string]$_.VideoPath)) -eq $oldPathKey -and
        [int]$_.Season -eq 2 -and [int]$_.Episode -eq 9
    }
)
if ($logMatch.Count -eq 0) { throw "Run log does not confirm S02E09 for this path." }

try { [xml]$nfo = Get-Content -LiteralPath $originalNfo -Raw } catch { throw "NFO is not valid XML: $($_.Exception.Message)" }
$seasonNode = $nfo.SelectSingleNode("//season")
$episodeNode = $nfo.SelectSingleNode("//episode")
if ($null -eq $seasonNode -or $null -eq $episodeNode) { throw "NFO is missing <season> or <episode>." }
if ([int]$seasonNode.InnerText -ne 2 -or [int]$episodeNode.InnerText -ne 9) { throw "NFO does not explicitly report S02E09." }

$dir = Split-Path -LiteralPath $originalVideo -Parent
$videoName = [System.IO.Path]::GetFileName($originalVideo)
$nfoName = [System.IO.Path]::GetFileName($originalNfo)
$canonicalVideo = Join-Path $dir ($CanonicalPrefix + $videoName)
$canonicalNfo = Join-Path $dir ($CanonicalPrefix + $nfoName)
if (Test-Path -LiteralPath $canonicalVideo) { throw "Canonical video path already exists: $canonicalVideo" }
if (Test-Path -LiteralPath $canonicalNfo) { throw "Canonical NFO path already exists: $canonicalNfo" }

# Find the one library root containing this file, and require realtime monitoring.
$librariesRaw = Invoke-JfGet -Uri "$Server/Library/VirtualFolders"
$libraries = @()
foreach ($libraryEntry in $librariesRaw) { $libraries += $libraryEntry }
$libraryCount = 0
$libraryName = ""
$libraryRoot = ""
$libraryRealtime = $false
$allRoots = @()
foreach ($library in $libraries) {
    foreach ($location in @($library.Locations)) {
        if ([string]::IsNullOrWhiteSpace([string]$location)) { continue }
        $allRoots += [string]$location
        if (Test-InsideRoot -Path $originalVideo -Root ([string]$location)) {
            $libraryCount += 1
            $libraryName = [string]$library.Name
            $libraryRoot = [string]$location
            $libraryRealtime = [bool]$library.LibraryOptions.EnableRealtimeMonitor
        }
    }
}
if ($libraryCount -ne 1) { throw "Expected exactly one containing library root; found $libraryCount." }
if (-not $libraryRealtime) { throw "Containing library does not have realtime monitoring enabled." }

if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $StagingRoot = Join-Path ([System.IO.Path]::GetPathRoot($originalVideo)) "_jellyfin_repair_staging"
}
$StagingRoot = [System.IO.Path]::GetFullPath($StagingRoot)
if ([System.IO.Path]::GetPathRoot($StagingRoot) -ne [System.IO.Path]::GetPathRoot($originalVideo)) {
    throw "StagingRoot must be on the same drive as the video."
}
foreach ($root in $allRoots) {
    if (Test-InsideRoot -Path $StagingRoot -Root $root) { throw "StagingRoot is inside a Jellyfin library: $root" }
}

$stagingFolder = Join-Path $StagingRoot ("medalist-s02e09-canonical-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$stagedVideo = Join-Path $stagingFolder $videoName
$stagedNfo = Join-Path $stagingFolder $nfoName

Write-Host ""
Write-Host "=== Preflight passed ==="
Write-Host "Library:         $libraryName"
Write-Host "Library root:    $libraryRoot"
Write-Host "Realtime:        $libraryRealtime"
Write-Host "Original video:  $originalVideo"
Write-Host "Canonical video: $canonicalVideo"
Write-Host "Canonical NFO:   $canonicalNfo"
Write-Host "Staging root:    $StagingRoot"
Write-Host "Owner sources:   8"
Write-Host "Old target key:  S02E09"
Write-Host ""

if (-not $Apply) {
    Write-Host "DRY RUN finished. No files or Jellyfin data were changed."
    Write-Host ""
    Write-Host "Apply command:"
    Write-Host "  .\experiments\jellyfin12-nfo-refresh\13-medalist-e09-canonical-name-pilot.ps1 -ApiKey <API_KEY> -Apply"
    return
}

New-Item -ItemType Directory -Path $stagingFolder -Force | Out-Null
$videoStaged = $false
$nfoStaged = $false

try {
    Write-Host ""
    Write-Host "=== Phase 1: remove original-name S02E09 ==="
    Move-Item -LiteralPath $originalNfo -Destination $stagedNfo
    $nfoStaged = $true
    Move-Item -LiteralPath $originalVideo -Destination $stagedVideo
    $videoStaged = $true

    $removalDeadline = (Get-Date).AddSeconds($RemovalTimeoutSeconds)
    $removed = $false
    while ((Get-Date) -lt $removalDeadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $ownerState = Get-OwnerState -ObservedPath $originalVideo
        $oldExpandedNow = Get-EpisodeById -ItemId $OldTargetId -Expanded
        Write-Host ("Removal state: ownerSources={0}, ownerHasOldPath={1}, oldExpanded={2}" -f `
            $ownerState.SourceCount, $ownerState.ContainsPath, ($null -ne $oldExpandedNow))
        if ($ownerState.Found -and $ownerState.SourceCount -eq 7 -and -not $ownerState.ContainsPath -and $null -eq $oldExpandedNow) {
            $removed = $true
            break
        }
    }

    if (-not $removed) {
        Write-Host "Removal timeout. Restoring original filenames before stopping."
        if ($nfoStaged -and -not (Test-Path -LiteralPath $originalNfo)) { Move-Item -LiteralPath $stagedNfo -Destination $originalNfo; $nfoStaged = $false }
        if ($videoStaged -and -not (Test-Path -LiteralPath $originalVideo)) { Move-Item -LiteralPath $stagedVideo -Destination $originalVideo; $videoStaged = $false }
        throw "Removal phase did not reach the expected 7-source state."
    }

    Write-Host "Removal confirmed."
    Write-Host ""
    Write-Host "=== Phase 2: add explicit S02E09 filename ==="

    # Put NFO back first so it already exists when the video appears.
    Move-Item -LiteralPath $stagedNfo -Destination $canonicalNfo
    $nfoStaged = $false
    Move-Item -LiteralPath $stagedVideo -Destination $canonicalVideo
    $videoStaged = $false

    $deadline = (Get-Date).AddSeconds($ReaddTimeoutSeconds)
    $lastSignature = ""
    $stableCount = 0
    $stableState = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-ObservedState -Path $canonicalVideo
        $signature = Get-StateSignature -State $state
        Write-Host "Canonical state: $signature"

        if (-not $state.TargetExpanded) {
            $lastSignature = ""
            $stableCount = 0
            continue
        }

        if ($signature -eq $lastSignature) { $stableCount += 1 } else { $lastSignature = $signature; $stableCount = 1 }
        if ($stableCount -ge $StableSamples) { $stableState = $state; break }
    }

    Write-Host ""
    Write-Host "=== Final observed state ==="
    if ($null -eq $stableState) {
        Write-Host "RESULT: INCONCLUSIVE"
        Write-Host "The canonical path did not stabilize before timeout. It is left in place for inspection."
        return
    }

    $seriesVisible = Get-SeriesVisible -Path $canonicalVideo
    Write-Host "Owner source count:        $($stableState.OwnerSourceCount)"
    Write-Host "Owner contains canonical:  $($stableState.OwnerContainsTarget)"
    Write-Host "Target normally visible:   $($stableState.TargetNormal)"
    Write-Host "Target expanded visible:   $($stableState.TargetExpanded)"
    Write-Host "Target new ItemId:          $($stableState.TargetId)"
    Write-Host "Target current key:         $($stableState.TargetKey)"
    Write-Host "Target media-source count:  $($stableState.TargetMediaSources)"
    Write-Host "Target SeriesId:            $($stableState.TargetSeriesId)"
    Write-Host "Target SeasonId:            $($stableState.TargetSeasonId)"
    Write-Host "Visible through Series:     $seriesVisible"
    Write-Host "Canonical video path:       $canonicalVideo"
    Write-Host ""

    $independent = (
        $stableState.OwnerSourceCount -eq 7 -and
        -not $stableState.OwnerContainsTarget -and
        $stableState.TargetNormal -and
        $stableState.TargetExpanded -and
        $stableState.TargetKey -eq $ExpectedTargetKey -and
        $stableState.TargetMediaSources -eq 1 -and
        $stableState.TargetSeriesId -eq $SeriesId
    )

    $remerged = (
        $stableState.OwnerSourceCount -eq 8 -and
        $stableState.OwnerContainsTarget -and
        -not $stableState.TargetNormal -and
        $stableState.TargetExpanded -and
        $stableState.TargetMediaSources -eq 8
    )

    if ($independent) {
        Write-Host "RESULT: CANONICAL NAME STAYS INDEPENDENT" -ForegroundColor Green
        Write-Host "The explicit S02E09 prefix prevented this file from being grouped under S02E02."
        Write-Host "The canonical filename is intentionally left in place for UI inspection."
    }
    elseif ($remerged) {
        Write-Host "RESULT: CANONICAL NAME STILL RE-MERGED" -ForegroundColor Yellow
        Write-Host "The explicit S02E09 prefix did not prevent the 8-source grouping."
        Write-Host "The canonical filename is left in place so this exact state can be inspected."
    }
    else {
        Write-Host "RESULT: PARTIAL / OTHER STATE" -ForegroundColor Yellow
        Write-Host "Do not rerun this pilot. Inspect the current state first."
    }

    Write-Host "No SQLite writes and no metadata refresh were performed."
}
catch {
    if ($nfoStaged -and -not (Test-Path -LiteralPath $originalNfo)) {
        try { Move-Item -LiteralPath $stagedNfo -Destination $originalNfo; $nfoStaged = $false } catch { Write-Host "NFO rollback failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($videoStaged -and -not (Test-Path -LiteralPath $originalVideo)) {
        try { Move-Item -LiteralPath $stagedVideo -Destination $originalVideo; $videoStaged = $false } catch { Write-Host "Video rollback failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingFolder -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue }
    }
}
