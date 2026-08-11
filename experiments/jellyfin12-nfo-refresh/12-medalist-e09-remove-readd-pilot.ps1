# MEDALIST S02E09 REMOVE / RE-ADD PILOT
#
# Purpose:
# Test whether Jellyfin 12 will rebuild one stale LocalAlternateVersion member
# correctly if that physical Episode is temporarily removed from the library and
# then re-added with its already-correct NFO beside it.
#
# Scope is intentionally tiny:
# - target only Medalist S02E09
# - do not touch SQLite
# - do not refresh metadata
# - do not call alternate-source DELETE APIs
# - do not touch S02E02-S02E08 media files
#
# Default mode is DRY RUN. -Apply is required to move files.
# In Apply mode this script moves only the target video and same-basename .nfo
# to a staging directory on the SAME drive, waits for Jellyfin to forget the
# old item, then moves both files back and observes how Jellyfin rebuilds it.

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

if ($PollIntervalSeconds -lt 1) {
    throw "PollIntervalSeconds must be at least 1."
}
if ($RemovalTimeoutSeconds -lt 10) {
    throw "RemovalTimeoutSeconds must be at least 10."
}
if ($ReaddTimeoutSeconds -lt 10) {
    throw "ReaddTimeoutSeconds must be at least 10."
}
if ($StableSamples -lt 2) {
    throw "StableSamples must be at least 2."
}

$OwnerId = "af564551c864a8892b28736b0de926de"   # Medalist S02E02 owner
$TargetId = "59a625fe5a7b8584017e2707eea78cd3"  # Medalist S02E09
$SeriesId = "1e343af25a95b525ae23adc50142693a"
$ExpectedOwnerKey = "S02E02"
$ExpectedTargetKey = "S02E09"

$Headers = @{
    Authorization = "MediaBrowser Client=`"remove-readd-pilot`", Device=`"PowerShell`", DeviceId=`"remove-readd-pilot`", Version=`"1.0`", Token=`"$ApiKey`""
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

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([char[]]@('\', '/'))
}

function Get-PathKey {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return (Get-NormalizedPath -Path $Path).ToLowerInvariant()
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $pathFull = Get-NormalizedPath -Path $Path
    $rootFull = Get-NormalizedPath -Path $Root

    if ([string]::Equals($pathFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
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

function Get-EpisodeById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemId,

        [switch]$Expanded
    )

    $fields = [uri]::EscapeDataString("Path,MediaSources,MediaSourceCount,SeriesId,SeasonId")
    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&Fields=$fields&EnableImages=false&EnableUserData=false"

    if ($Expanded) {
        $uri += "&VideoTypes=VideoFile"
    }

    $response = Invoke-JellyfinGet -Uri $uri
    $items = @($response.Items)

    if ($items.Count -eq 0) {
        return $null
    }

    return $items[0]
}

function Get-SeriesEpisodes {
    $fields = [uri]::EscapeDataString("Path,MediaSourceCount")
    $uri = "$Server/Shows/$SeriesId/Episodes?Fields=$fields&EnableImages=false&EnableUserData=false&Limit=500"
    $response = Invoke-JellyfinGet -Uri $uri
    return @($response.Items)
}

function Get-OwnerSourceCount {
    $owner = Get-EpisodeById -ItemId $OwnerId
    if ($null -eq $owner) {
        return -1
    }
    return @($owner.MediaSources).Count
}

function Test-OwnerContainsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $owner = Get-EpisodeById -ItemId $OwnerId
    if ($null -eq $owner) {
        return $false
    }

    $wanted = Get-PathKey -Path $Path
    foreach ($source in @($owner.MediaSources)) {
        if ((Get-PathKey -Path ([string]$source.Path)) -eq $wanted) {
            return $true
        }
    }

    return $false
}

function Get-CurrentState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $owner = Get-EpisodeById -ItemId $OwnerId
    $targetNormal = Get-EpisodeById -ItemId $TargetId
    $targetExpanded = Get-EpisodeById -ItemId $TargetId -Expanded

    $ownerCount = if ($null -ne $owner) { @($owner.MediaSources).Count } else { -1 }
    $ownerContainsTarget = $false
    if ($null -ne $owner) {
        $wanted = Get-PathKey -Path $TargetPath
        foreach ($source in @($owner.MediaSources)) {
            if ((Get-PathKey -Path ([string]$source.Path)) -eq $wanted) {
                $ownerContainsTarget = $true
                break
            }
        }
    }

    return [pscustomobject]@{
        OwnerFound          = $null -ne $owner
        OwnerSourceCount    = $ownerCount
        OwnerContainsTarget = $ownerContainsTarget
        TargetNormal        = $null -ne $targetNormal
        TargetExpanded      = $null -ne $targetExpanded
        TargetKey           = if ($null -ne $targetExpanded) { Get-EpisodeKey -Item $targetExpanded } else { "" }
        TargetMediaSources  = if ($null -ne $targetExpanded) { @($targetExpanded.MediaSources).Count } else { 0 }
        TargetSeasonId      = if ($null -ne $targetExpanded) { [string]$targetExpanded.SeasonId } else { "" }
        TargetSeriesId      = if ($null -ne $targetExpanded) { [string]$targetExpanded.SeriesId } else { "" }
        TargetPath          = if ($null -ne $targetExpanded) { [string]$targetExpanded.Path } else { "" }
    }
}

function Format-StateSignature {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    return "owner={0};ownerHasTarget={1};normal={2};expanded={3};key={4};targetSources={5}" -f `
        $State.OwnerSourceCount,
        $State.OwnerContainsTarget,
        $State.TargetNormal,
        $State.TargetExpanded,
        $State.TargetKey,
        $State.TargetMediaSources
}

function Restore-TargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalVideo,

        [Parameter(Mandatory = $true)]
        [string]$OriginalNfo,

        [Parameter(Mandatory = $true)]
        [string]$StagedVideo,

        [Parameter(Mandatory = $true)]
        [string]$StagedNfo
    )

    # Put the NFO back first so it is already present when the video reappears.
    if ((Test-Path -LiteralPath $StagedNfo -PathType Leaf) -and
        -not (Test-Path -LiteralPath $OriginalNfo -PathType Leaf)) {
        Move-Item -LiteralPath $StagedNfo -Destination $OriginalNfo
    }

    if ((Test-Path -LiteralPath $StagedVideo -PathType Leaf) -and
        -not (Test-Path -LiteralPath $OriginalVideo -PathType Leaf)) {
        Move-Item -LiteralPath $StagedVideo -Destination $OriginalVideo
    }
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}

Write-Host ""
Write-Host "=== Medalist S02E09 Remove / Re-add Pilot ==="
if ($Apply) {
    Write-Host "Mode: APPLY" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: DRY RUN" -ForegroundColor Cyan
}
Write-Host "OwnerId:  $OwnerId ($ExpectedOwnerKey)"
Write-Host "TargetId: $TargetId ($ExpectedTargetKey)"
Write-Host "SeriesId: $SeriesId"
Write-Host ""

$systemInfo = Invoke-JellyfinGet -Uri "$Server/System/Info"
Write-Host "Server version: $($systemInfo.Version)"

Write-Host "Reading current Jellyfin state..."
$owner = Get-EpisodeById -ItemId $OwnerId
$targetNormal = Get-EpisodeById -ItemId $TargetId
$targetExpanded = Get-EpisodeById -ItemId $TargetId -Expanded

if ($null -eq $owner) {
    throw "Owner is not normally visible. State changed; aborting."
}
if ([string]$owner.SeriesId -ne $SeriesId) {
    throw "Owner SeriesId changed; aborting."
}
if ((Get-EpisodeKey -Item $owner) -ne $ExpectedOwnerKey) {
    throw "Owner no longer reports $ExpectedOwnerKey; aborting."
}
if (@($owner.MediaSources).Count -ne 8) {
    throw "Expected owner to expose exactly 8 media sources before the pilot; found $(@($owner.MediaSources).Count)."
}

if ($null -ne $targetNormal) {
    throw "Target is already normally visible. The stale relationship may already be gone; aborting."
}
if ($null -eq $targetExpanded) {
    throw "Target is not visible even in expanded Episode view; aborting."
}
if ([string]$targetExpanded.SeriesId -ne $SeriesId) {
    throw "Target SeriesId changed; aborting."
}
if ((Get-EpisodeKey -Item $targetExpanded) -ne $ExpectedTargetKey) {
    throw "Target no longer reports $ExpectedTargetKey; aborting."
}

$targetPath = Get-NormalizedPath -Path ([string]$targetExpanded.Path)
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Target media file does not exist: $targetPath"
}

$nfoPath = [System.IO.Path]::ChangeExtension($targetPath, ".nfo")
if (-not (Test-Path -LiteralPath $nfoPath -PathType Leaf)) {
    throw "Expected same-basename NFO does not exist: $nfoPath"
}

$ownerHasTarget = $false
$targetPathKey = Get-PathKey -Path $targetPath
foreach ($source in @($owner.MediaSources)) {
    if ((Get-PathKey -Path ([string]$source.Path)) -eq $targetPathKey) {
        $ownerHasTarget = $true
        break
    }
}
if (-not $ownerHasTarget) {
    throw "Owner's 8-source group does not contain the target path; aborting."
}

Write-Host "Validating correction run log..."
$matchingRows = @(
    Import-Csv -LiteralPath $RunLogPath |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.VideoPath) -and
        (Get-PathKey -Path ([string]$_.VideoPath)) -eq $targetPathKey
    }
)

if ($matchingRows.Count -eq 0) {
    throw "Target path is not present in the NFO correction run log."
}

$matchingTargetRows = @(
    $matchingRows |
    Where-Object {
        [string]$_.RuleId -ne "series-nfo" -and
        [int]$_.Season -eq 2 -and
        [int]$_.Episode -eq 9
    }
)

if ($matchingTargetRows.Count -eq 0) {
    throw "Run log does not confirm S02E09 for the target path."
}

Write-Host "Validating NFO season/episode..."
try {
    [xml]$nfoXml = Get-Content -LiteralPath $nfoPath -Raw
}
catch {
    throw "NFO is not valid XML: $($_.Exception.Message)"
}

$seasonNode = $nfoXml.SelectSingleNode("//season")
$episodeNode = $nfoXml.SelectSingleNode("//episode")
if ($null -eq $seasonNode -or $null -eq $episodeNode) {
    throw "NFO is missing <season> or <episode>."
}
if ([int]$seasonNode.InnerText -ne 2 -or [int]$episodeNode.InnerText -ne 9) {
    throw "NFO does not explicitly report S02E09."
}

Write-Host "Reading library locations..."
$libraries = @(Invoke-JellyfinGet -Uri "$Server/Library/VirtualFolders")
$containingLibraries = @()
$allLibraryLocations = @()

foreach ($library in $libraries) {
    foreach ($location in @($library.Locations)) {
        if ([string]::IsNullOrWhiteSpace([string]$location)) {
            continue
        }

        $locationFull = Get-NormalizedPath -Path ([string]$location)
        $allLibraryLocations += $locationFull

        if (Test-PathInsideRoot -Path $targetPath -Root $locationFull) {
            $containingLibraries += [pscustomobject]@{
                Name                  = [string]$library.Name
                Location              = $locationFull
                EnableRealtimeMonitor = [bool]$library.LibraryOptions.EnableRealtimeMonitor
            }
        }
    }
}

if ($containingLibraries.Count -ne 1) {
    throw "Expected target to belong to exactly one Jellyfin library location; found $($containingLibraries.Count)."
}

$targetLibrary = $containingLibraries[0]
if (-not $targetLibrary.EnableRealtimeMonitor) {
    throw "Containing library does not have realtime monitoring enabled; aborting this pilot."
}

if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $driveRoot = [System.IO.Path]::GetPathRoot($targetPath)
    $StagingRoot = Join-Path $driveRoot "_jellyfin_repair_staging"
}
$StagingRoot = Get-NormalizedPath -Path $StagingRoot

$targetDrive = [System.IO.Path]::GetPathRoot($targetPath)
$stagingDrive = [System.IO.Path]::GetPathRoot($StagingRoot)
if (-not [string]::Equals($targetDrive, $stagingDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "StagingRoot must be on the same drive as the target media so the pilot is a same-volume move."
}

foreach ($location in $allLibraryLocations) {
    if (Test-PathInsideRoot -Path $StagingRoot -Root $location) {
        throw "StagingRoot is inside a Jellyfin library location: $location"
    }
}

$runFolderName = "medalist-s02e09-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$stagingFolder = Join-Path $StagingRoot $runFolderName
$stagedVideo = Join-Path $stagingFolder ([System.IO.Path]::GetFileName($targetPath))
$stagedNfo = Join-Path $stagingFolder ([System.IO.Path]::GetFileName($nfoPath))

Write-Host ""
Write-Host "=== Preflight passed ==="
Write-Host "Library:      $($targetLibrary.Name)"
Write-Host "Library root: $($targetLibrary.Location)"
Write-Host "Realtime:     $($targetLibrary.EnableRealtimeMonitor)"
Write-Host "Target video: $targetPath"
Write-Host "Target NFO:   $nfoPath"
Write-Host "Staging root: $StagingRoot"
Write-Host "Owner sources before move: $(@($owner.MediaSources).Count)"
Write-Host "Target normal visibility:  False"
Write-Host "Target expanded key:       $(Get-EpisodeKey -Item $targetExpanded)"
Write-Host ""

if (-not $Apply) {
    Write-Host "DRY RUN finished."
    Write-Host "No files or Jellyfin data were changed."
    Write-Host ""
    Write-Host "Apply command:"
    Write-Host "  .\experiments\jellyfin12-nfo-refresh\12-medalist-e09-remove-readd-pilot.ps1 -ApiKey <API_KEY> -Apply"
    return
}

if (Test-Path -LiteralPath $stagingFolder) {
    throw "Staging folder already exists unexpectedly: $stagingFolder"
}

New-Item -ItemType Directory -Path $stagingFolder -Force | Out-Null

$videoMovedOut = $false
$nfoMovedOut = $false

try {
    Write-Host ""
    Write-Host "=== Phase 1: move S02E09 out of all Jellyfin libraries ==="
    Write-Host "Moving NFO to staging..."
    Move-Item -LiteralPath $nfoPath -Destination $stagedNfo
    $nfoMovedOut = $true

    Write-Host "Moving video to staging..."
    Move-Item -LiteralPath $targetPath -Destination $stagedVideo
    $videoMovedOut = $true

    if (-not (Test-Path -LiteralPath $stagedVideo -PathType Leaf) -or
        -not (Test-Path -LiteralPath $stagedNfo -PathType Leaf)) {
        throw "Staging move did not produce both expected files."
    }

    Write-Host "Waiting for Jellyfin to forget the old S02E09 item..."
    $removalDeadline = (Get-Date).AddSeconds($RemovalTimeoutSeconds)
    $removalConfirmed = $false

    while ((Get-Date) -lt $removalDeadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-CurrentState -TargetPath $targetPath
        Write-Host ("Removal state: ownerSources={0}, ownerHasTarget={1}, targetExpanded={2}, targetNormal={3}" -f `
            $state.OwnerSourceCount,
            $state.OwnerContainsTarget,
            $state.TargetExpanded,
            $state.TargetNormal)

        if ($state.OwnerFound -and
            $state.OwnerSourceCount -eq 7 -and
            -not $state.OwnerContainsTarget -and
            -not $state.TargetExpanded -and
            -not $state.TargetNormal) {
            $removalConfirmed = $true
            break
        }
    }

    if (-not $removalConfirmed) {
        Write-Host ""
        Write-Host "REMOVAL TIMEOUT: Jellyfin did not reach the expected 7-source / target-missing state."
        Write-Host "Rolling the files back before stopping..."

        Restore-TargetFiles `
            -OriginalVideo $targetPath `
            -OriginalNfo $nfoPath `
            -StagedVideo $stagedVideo `
            -StagedNfo $stagedNfo

        $videoMovedOut = $false
        $nfoMovedOut = $false

        $rollbackDeadline = (Get-Date).AddSeconds($ReaddTimeoutSeconds)
        $rollbackConfirmed = $false

        while ((Get-Date) -lt $rollbackDeadline) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $rollbackState = Get-CurrentState -TargetPath $targetPath
            Write-Host ("Rollback state: ownerSources={0}, ownerHasTarget={1}, targetExpanded={2}, targetNormal={3}, key={4}" -f `
                $rollbackState.OwnerSourceCount,
                $rollbackState.OwnerContainsTarget,
                $rollbackState.TargetExpanded,
                $rollbackState.TargetNormal,
                $rollbackState.TargetKey)

            if ($rollbackState.OwnerFound -and
                $rollbackState.OwnerSourceCount -eq 8 -and
                $rollbackState.OwnerContainsTarget -and
                $rollbackState.TargetExpanded -and
                -not $rollbackState.TargetNormal -and
                $rollbackState.TargetKey -eq $ExpectedTargetKey) {
                $rollbackConfirmed = $true
                break
            }
        }

        if ($rollbackConfirmed) {
            throw "Removal phase timed out, but the original 8-source stale state was restored successfully. Stop here."
        }

        throw "Removal phase timed out and Jellyfin did not return to the original state after rollback. Stop here and send the full output for analysis."
    }

    Write-Host ""
    Write-Host "Removal confirmed: owner dropped from 8 to 7 sources and S02E09 disappeared from expanded view."

    Write-Host ""
    Write-Host "=== Phase 2: move the same NFO and video back ==="

    # Put the NFO back first. The correct S02E09 metadata is therefore already
    # present when the video file reappears to Jellyfin's filesystem watcher.
    Move-Item -LiteralPath $stagedNfo -Destination $nfoPath
    $nfoMovedOut = $false

    Move-Item -LiteralPath $stagedVideo -Destination $targetPath
    $videoMovedOut = $false

    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $nfoPath -PathType Leaf)) {
        throw "Re-add move did not restore both expected files to the original directory."
    }

    Write-Host "Files restored to their original paths."
    Write-Host "Waiting for Jellyfin's rebuilt state to stabilize..."

    $readdDeadline = (Get-Date).AddSeconds($ReaddTimeoutSeconds)
    $lastSignature = ""
    $sameSignatureCount = 0
    $stableState = $null

    while ((Get-Date) -lt $readdDeadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-CurrentState -TargetPath $targetPath
        $signature = Format-StateSignature -State $state

        Write-Host ("Re-add state: {0}" -f $signature)

        if (-not $state.TargetExpanded) {
            $lastSignature = ""
            $sameSignatureCount = 0
            continue
        }

        if ($signature -eq $lastSignature) {
            $sameSignatureCount += 1
        }
        else {
            $lastSignature = $signature
            $sameSignatureCount = 1
        }

        if ($sameSignatureCount -ge $StableSamples) {
            $stableState = $state
            break
        }
    }

    Write-Host ""
    Write-Host "=== Final observed state ==="

    if ($null -eq $stableState) {
        Write-Host "INCONCLUSIVE: S02E09 did not reach a stable expanded-visible state before timeout."
        Write-Host "The video and NFO are already back at their original paths."
        Write-Host "No metadata refresh or database write was attempted."
        return
    }

    $seriesEpisodes = @(Get-SeriesEpisodes)
    $seriesVisible = $false
    foreach ($episode in $seriesEpisodes) {
        if ((Get-PathKey -Path ([string]$episode.Path)) -eq $targetPathKey) {
            $seriesVisible = $true
            break
        }
    }

    Write-Host "Owner source count:       $($stableState.OwnerSourceCount)"
    Write-Host "Owner contains target:    $($stableState.OwnerContainsTarget)"
    Write-Host "Target normally visible:  $($stableState.TargetNormal)"
    Write-Host "Target expanded visible:  $($stableState.TargetExpanded)"
    Write-Host "Target current key:       $($stableState.TargetKey)"
    Write-Host "Target media-source count:$($stableState.TargetMediaSources)"
    Write-Host "Target SeasonId:          $($stableState.TargetSeasonId)"
    Write-Host "Visible through Series:   $seriesVisible"
    Write-Host ""

    $independent = (
        $stableState.OwnerSourceCount -eq 7 -and
        -not $stableState.OwnerContainsTarget -and
        $stableState.TargetNormal -and
        $stableState.TargetExpanded -and
        $stableState.TargetKey -eq $ExpectedTargetKey -and
        $stableState.TargetMediaSources -eq 1
    )

    $remerged = (
        $stableState.OwnerSourceCount -eq 8 -and
        $stableState.OwnerContainsTarget -and
        -not $stableState.TargetNormal -and
        $stableState.TargetExpanded -and
        $stableState.TargetKey -eq $ExpectedTargetKey -and
        $stableState.TargetMediaSources -eq 8
    )

    if ($independent) {
        Write-Host "RESULT: INDEPENDENT RE-ADD" -ForegroundColor Green
        Write-Host "Jellyfin rebuilt S02E09 as its own Episode instead of restoring the stale E02 alternate relationship."
        if ($seriesVisible) {
            Write-Host "It is also visible through the Series Episode list."
        }
        else {
            Write-Host "It is normally visible but not yet visible through the Series Episode list; do not refresh yet."
        }
        Write-Host "This strongly supports treating the bad alternate groups as stale historical database state."
    }
    elseif ($remerged) {
        Write-Host "RESULT: RE-MERGED AS LOCAL ALTERNATE" -ForegroundColor Yellow
        Write-Host "Jellyfin recreated the same 8-source relationship after the physical file was re-added."
        Write-Host "That means the current import/resolver path can still reproduce the bad grouping."
        Write-Host "Do not attempt global database cleanup based on stale-state assumptions."
    }
    else {
        Write-Host "RESULT: PARTIAL / OTHER STATE" -ForegroundColor Yellow
        Write-Host "The rebuilt state does not match either clean independent re-add or the original 8-source stale group."
        Write-Host "Do not refresh metadata or rerun this pilot. Send the full output for analysis."
    }

    Write-Host ""
    Write-Host "No metadata refresh and no SQLite modification were performed."
}
catch {
    if ($videoMovedOut -or $nfoMovedOut) {
        Write-Host ""
        Write-Host "An error occurred while one or more target files were still staged. Attempting file rollback..."
        try {
            Restore-TargetFiles `
                -OriginalVideo $targetPath `
                -OriginalNfo $nfoPath `
                -StagedVideo $stagedVideo `
                -StagedNfo $stagedNfo
            Write-Host "File rollback attempt completed. Verify Jellyfin state before rerunning anything."
        }
        catch {
            Write-Host "ROLLBACK ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Staging folder: $stagingFolder"
        }
    }

    throw
}
finally {
    if (Test-Path -LiteralPath $stagingFolder -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue
        }
    }
}
