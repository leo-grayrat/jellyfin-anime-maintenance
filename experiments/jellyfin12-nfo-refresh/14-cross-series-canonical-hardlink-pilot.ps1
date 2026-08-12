# CROSS-SERIES CANONICAL HARDLINK PILOT
#
# Final single-item validation before building the 243-target canonical view.
# The script automatically selects one clean non-Medalist wrong alternate group,
# removes one hidden non-owner correction target, then re-adds the same payload
# as a temporary hard link named "SxxEyy - <original filename>".
#
# Default mode is DRY RUN. -Apply is required for any filesystem change.
# The Apply path always attempts to restore the exact original video/NFO layout.
#
# This script does NOT:
# - write SQLite
# - call metadata FullRefresh
# - call /Videos/{id}/AlternateSources
# - modify NFO XML
# - touch correction-target-unknown group members

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

    [int]$ObservationTimeoutSeconds = 180,

    [int]$RestoreTimeoutSeconds = 180,

    [int]$StableSamples = 5
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($PollIntervalSeconds -lt 1) { throw "PollIntervalSeconds must be at least 1." }
if ($RemovalTimeoutSeconds -lt 10) { throw "RemovalTimeoutSeconds must be at least 10." }
if ($ObservationTimeoutSeconds -lt 10) { throw "ObservationTimeoutSeconds must be at least 10." }
if ($RestoreTimeoutSeconds -lt 10) { throw "RestoreTimeoutSeconds must be at least 10." }
if ($StableSamples -lt 2) { throw "StableSamples must be at least 2." }

$ExcludedSeriesId = "1e343af25a95b525ae23adc50142693a" # Medalist
$ExpectedTargetCount = 243

$Headers = @{
    Authorization = "MediaBrowser Client=`"cross-series-hardlink-pilot`", Device=`"PowerShell`", DeviceId=`"cross-series-hardlink-pilot`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-PathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
    }
    catch {
        return $Path.Trim().TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
    }
}

function Test-InsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $pathFull = Get-PathKey -Path $Path
    $rootFull = Get-PathKey -Path $Root

    if ($pathFull -eq $rootFull) { return $true }
    return $pathFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-EpisodeKey {
    param($Season, $Episode)

    if ($null -eq $Season -or $null -eq $Episode) { return "" }
    return "S{0:D2}E{1:D2}" -f [int]$Season, [int]$Episode
}

function Get-ItemEpisodeKey {
    param($Item)

    if ($null -eq $Item) { return "" }
    return Get-EpisodeKey -Season $Item.ParentIndexNumber -Episode $Item.IndexNumber
}

function Get-AllEpisodes {
    param(
        [switch]$Expanded,
        [switch]$IncludeMediaSources
    )

    $start = 0
    $limit = 500
    $all = @()

    do {
        $fields = "Path,MediaSourceCount,SeriesId,SeasonId,SeriesName"
        if ($IncludeMediaSources) {
            $fields = "Path,MediaSources,MediaSourceCount,SeriesId,SeasonId,SeriesName"
        }

        $uri = "$Server/Items?Recursive=true&StartIndex=$start&Limit=$limit&IncludeItemTypes=Episode&Fields=$([uri]::EscapeDataString($fields))&EnableImages=false&EnableUserData=false"
        if ($Expanded) { $uri += "&VideoTypes=VideoFile" }

        $response = Invoke-JfGet -Uri $uri
        $page = @($response.Items)
        $all += $page
        $start += $page.Count
    } while ($page.Count -gt 0 -and $start -lt $response.TotalRecordCount)

    return @($all)
}

function Get-EpisodeById {
    param(
        [Parameter(Mandatory = $true)][string]$ItemId,
        [switch]$Expanded,
        [switch]$IncludeMediaSources
    )

    $fields = "Path,MediaSourceCount,SeriesId,SeasonId,SeriesName"
    if ($IncludeMediaSources) {
        $fields = "Path,MediaSources,MediaSourceCount,SeriesId,SeasonId,SeriesName"
    }

    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=Episode&Fields=$([uri]::EscapeDataString($fields))&EnableImages=false&EnableUserData=false"
    if ($Expanded) { $uri += "&VideoTypes=VideoFile" }

    $response = Invoke-JfGet -Uri $uri
    $items = @($response.Items)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Get-EpisodeByPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Expanded
    )

    $wanted = Get-PathKey -Path $Path
    $items = if ($Expanded) { @(Get-AllEpisodes -Expanded -IncludeMediaSources) } else { @(Get-AllEpisodes -IncludeMediaSources) }

    foreach ($item in $items) {
        if ((Get-PathKey -Path ([string]$item.Path)) -eq $wanted) { return $item }
    }

    return $null
}

function Get-SeriesVisible {
    param(
        [Parameter(Mandatory = $true)][string]$SeriesId,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $wanted = Get-PathKey -Path $Path
    $fields = [uri]::EscapeDataString("Path")
    $response = Invoke-JfGet -Uri "$Server/Shows/$SeriesId/Episodes?Fields=$fields&EnableImages=false&EnableUserData=false&Limit=500"

    foreach ($item in @($response.Items)) {
        if ((Get-PathKey -Path ([string]$item.Path)) -eq $wanted) { return $true }
    }

    return $false
}

function Get-OwnerState {
    param(
        [Parameter(Mandatory = $true)][string]$OwnerId,
        [Parameter(Mandatory = $true)][string]$ObservedPath
    )

    $owner = Get-EpisodeById -ItemId $OwnerId -IncludeMediaSources
    if ($null -eq $owner) {
        return [pscustomobject]@{
            Found        = $false
            SourceCount  = -1
            ContainsPath = $false
            Owner        = $null
        }
    }

    $wanted = Get-PathKey -Path $ObservedPath
    $contains = $false

    foreach ($source in @($owner.MediaSources)) {
        if ((Get-PathKey -Path ([string]$source.Path)) -eq $wanted) {
            $contains = $true
            break
        }
    }

    return [pscustomobject]@{
        Found        = $true
        SourceCount  = @($owner.MediaSources).Count
        ContainsPath = $contains
        Owner        = $owner
    }
}

function Get-ObservedState {
    param(
        [Parameter(Mandatory = $true)][string]$OwnerId,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normal = Get-EpisodeByPath -Path $Path
    $expanded = Get-EpisodeByPath -Path $Path -Expanded
    $ownerState = Get-OwnerState -OwnerId $OwnerId -ObservedPath $Path

    return [pscustomobject]@{
        OwnerFound          = $ownerState.Found
        OwnerSourceCount    = $ownerState.SourceCount
        OwnerContainsTarget = $ownerState.ContainsPath
        TargetNormal        = $null -ne $normal
        TargetExpanded      = $null -ne $expanded
        TargetId            = if ($null -ne $expanded) { [string]$expanded.Id } else { "" }
        TargetKey           = if ($null -ne $expanded) { Get-ItemEpisodeKey -Item $expanded } else { "" }
        TargetMediaSources  = if ($null -ne $expanded) { @($expanded.MediaSources).Count } else { 0 }
        TargetSeriesId      = if ($null -ne $expanded) { [string]$expanded.SeriesId } else { "" }
        TargetSeasonId      = if ($null -ne $expanded) { [string]$expanded.SeasonId } else { "" }
    }
}

function Get-StateSignature {
    param($State)

    return "owner={0};ownerHasPath={1};normal={2};expanded={3};id={4};key={5};sources={6};series={7};season={8}" -f `
        $State.OwnerSourceCount,
        $State.OwnerContainsTarget,
        $State.TargetNormal,
        $State.TargetExpanded,
        $State.TargetId,
        $State.TargetKey,
        $State.TargetMediaSources,
        $State.TargetSeriesId,
        $State.TargetSeasonId
}

function Wait-PathForgotten {
    param(
        [Parameter(Mandatory = $true)][string]$OwnerId,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ExpectedOwnerCount,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$Label = "Removal"
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-ObservedState -OwnerId $OwnerId -Path $Path
        Write-Host ("{0} state: ownerSources={1}, ownerHasPath={2}, normal={3}, expanded={4}" -f `
            $Label,
            $state.OwnerSourceCount,
            $state.OwnerContainsTarget,
            $state.TargetNormal,
            $state.TargetExpanded)

        if ($state.OwnerFound -and
            $state.OwnerSourceCount -eq $ExpectedOwnerCount -and
            -not $state.OwnerContainsTarget -and
            -not $state.TargetNormal -and
            -not $state.TargetExpanded) {
            return $true
        }
    }

    return $false
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}

Write-Host ""
Write-Host "=== Cross-Series Canonical Hardlink Pilot ==="
if ($Apply) { Write-Host "Mode: APPLY" -ForegroundColor Yellow } else { Write-Host "Mode: DRY RUN" -ForegroundColor Cyan }
Write-Host ""

$systemInfo = Invoke-JfGet -Uri "$Server/System/Info"
Write-Host "Server version: $($systemInfo.Version)"
Write-Host "Reading correction targets..."

$rows = @(Import-Csv -LiteralPath $RunLogPath)
$rawTargets = @(
    $rows |
    Where-Object {
        [string]$_.RuleId -ne "series-nfo" -and
        [string]$_.Action -eq "WRITE" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.VideoPath) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Season) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Episode)
    }
)

$targets = @()
foreach ($group in ($rawTargets | Group-Object -Property VideoPath)) {
    $seasons = @($group.Group | ForEach-Object { [int]$_.Season } | Sort-Object -Unique)
    $episodes = @($group.Group | ForEach-Object { [int]$_.Episode } | Sort-Object -Unique)

    if ($seasons.Count -ne 1 -or $episodes.Count -ne 1) {
        throw "Conflicting correction targets for path: $($group.Name)"
    }

    $row = $group.Group[0]
    $targets += [pscustomobject]@{
        Work          = [string]$row.Work
        RuleId        = [string]$row.RuleId
        VideoPath     = [System.IO.Path]::GetFullPath([string]$row.VideoPath)
        PathKey       = Get-PathKey -Path ([string]$row.VideoPath)
        TargetSeason  = [int]$row.Season
        TargetEpisode = [int]$row.Episode
        ExpectedKey   = Get-EpisodeKey -Season ([int]$row.Season) -Episode ([int]$row.Episode
        )
    }
}

if ($targets.Count -ne $ExpectedTargetCount) {
    throw "Expected exactly $ExpectedTargetCount WRITE correction targets, found $($targets.Count). Use the archived run log from this investigation before continuing."
}

$targetByPath = @{}
foreach ($target in $targets) {
    if ($targetByPath.ContainsKey($target.PathKey)) {
        throw "Duplicate normalized correction path: $($target.VideoPath)"
    }
    $targetByPath[$target.PathKey] = $target
}

Write-Host "Correction targets: $($targets.Count)"
Write-Host "Reading normally visible Episodes with MediaSources..."
$normalEpisodes = @(Get-AllEpisodes -IncludeMediaSources)
Write-Host "Normally visible Episodes: $($normalEpisodes.Count)"
Write-Host "Reading Episodes including local alternate/owned items..."
$expandedEpisodes = @(Get-AllEpisodes -Expanded -IncludeMediaSources)
Write-Host "Expanded Episodes: $($expandedEpisodes.Count)"

$normalByPath = @{}
$expandedByPath = @{}
foreach ($item in $normalEpisodes) {
    $key = Get-PathKey -Path ([string]$item.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) { $normalByPath[$key] = $item }
}
foreach ($item in $expandedEpisodes) {
    $key = Get-PathKey -Path ([string]$item.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) { $expandedByPath[$key] = $item }
}

Write-Host "Selecting one clean wrong group outside Medalist..."
$candidates = @()

foreach ($owner in $normalEpisodes) {
    $ownerSeriesId = [string]$owner.SeriesId
    if ([string]::IsNullOrWhiteSpace($ownerSeriesId) -or $ownerSeriesId -eq $ExcludedSeriesId) { continue }

    $sources = @($owner.MediaSources)
    if ($sources.Count -lt 2) { continue }

    $members = @()
    $groupClean = $true

    foreach ($source in $sources) {
        $sourcePath = [string]$source.Path
        $sourceKey = Get-PathKey -Path $sourcePath

        if (-not $targetByPath.ContainsKey($sourceKey) -or -not $expandedByPath.ContainsKey($sourceKey)) {
            $groupClean = $false
            break
        }

        $target = $targetByPath[$sourceKey]
        $expanded = $expandedByPath[$sourceKey]
        $currentKey = Get-ItemEpisodeKey -Item $expanded

        if ($currentKey -ne $target.ExpectedKey -or [string]$expanded.SeriesId -ne $ownerSeriesId) {
            $groupClean = $false
            break
        }

        $members += [pscustomobject]@{
            SourcePath    = [System.IO.Path]::GetFullPath($sourcePath)
            SourceKey     = $sourceKey
            Work          = $target.Work
            ExpectedKey   = $target.ExpectedKey
            TargetSeason  = $target.TargetSeason
            TargetEpisode = $target.TargetEpisode
            ExpandedId    = [string]$expanded.Id
            FoundNormally = $normalByPath.ContainsKey($sourceKey)
        }
    }

    if (-not $groupClean -or $members.Count -ne $sources.Count) { continue }

    $expectedKeys = @($members | ForEach-Object { $_.ExpectedKey } | Sort-Object -Unique)
    if ($expectedKeys.Count -ne $members.Count) { continue }

    $ownerPathKey = Get-PathKey -Path ([string]$owner.Path)
    $hiddenMembers = @(
        $members |
        Where-Object {
            $_.SourceKey -ne $ownerPathKey -and -not $_.FoundNormally
        } |
        Sort-Object ExpectedKey, SourcePath
    )

    if ($hiddenMembers.Count -eq 0) { continue }

    foreach ($hidden in $hiddenMembers) {
        $originalVideo = $hidden.SourcePath
        $originalNfo = [System.IO.Path]::ChangeExtension($originalVideo, ".nfo")

        if (-not (Test-Path -LiteralPath $originalVideo -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $originalNfo -PathType Leaf)) { continue }

        $dir = [System.IO.Path]::GetDirectoryName($originalVideo)
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }

        $prefix = "{0} - " -f $hidden.ExpectedKey
        $canonicalVideo = [System.IO.Path]::Combine($dir, $prefix + [System.IO.Path]::GetFileName($originalVideo))
        $canonicalNfo = [System.IO.Path]::Combine($dir, $prefix + [System.IO.Path]::GetFileName($originalNfo))

        if (Test-Path -LiteralPath $canonicalVideo) { continue }
        if (Test-Path -LiteralPath $canonicalNfo) { continue }

        $quarterPenalty = if ((Get-PathKey -Path $originalVideo).Contains("\2026-01\")) { 1 } else { 0 }

        $candidates += [pscustomobject]@{
            QuarterPenalty     = $quarterPenalty
            SourceCount        = $sources.Count
            SeriesName         = [string]$owner.SeriesName
            SeriesId           = $ownerSeriesId
            OwnerId            = [string]$owner.Id
            OwnerKey           = Get-ItemEpisodeKey -Item $owner
            OwnerPath          = [string]$owner.Path
            GroupExpectedKeys  = ($expectedKeys -join ", ")
            Work               = $hidden.Work
            ExpectedKey        = $hidden.ExpectedKey
            TargetSeason       = $hidden.TargetSeason
            TargetEpisode      = $hidden.TargetEpisode
            OldTargetId        = $hidden.ExpandedId
            OriginalVideo      = $originalVideo
            OriginalNfo        = $originalNfo
            CanonicalVideo     = $canonicalVideo
            CanonicalNfo       = $canonicalNfo
        }
    }
}

if ($candidates.Count -eq 0) {
    throw "No clean cross-series candidate found. Do not broaden the experiment automatically."
}

$selected = @(
    $candidates |
    Sort-Object QuarterPenalty, SourceCount, SeriesName, ExpectedKey, OriginalVideo
)[0]

# Validate the NFO itself before any mutation.
try { [xml]$nfoXml = Get-Content -LiteralPath $selected.OriginalNfo -Raw } catch { throw "Selected NFO is not valid XML: $($_.Exception.Message)" }
$seasonNode = $nfoXml.SelectSingleNode("//season")
$episodeNode = $nfoXml.SelectSingleNode("//episode")
if ($null -eq $seasonNode -or $null -eq $episodeNode) { throw "Selected NFO is missing <season> or <episode>." }
if ([int]$seasonNode.InnerText -ne [int]$selected.TargetSeason -or [int]$episodeNode.InnerText -ne [int]$selected.TargetEpisode) {
    throw "Selected NFO does not match $($selected.ExpectedKey)."
}

# Find the one library location containing the selected video and collect every
# configured library root so staging can be proven outside Jellyfin libraries.
$librariesRaw = Invoke-JfGet -Uri "$Server/Library/VirtualFolders"
$libraries = @($librariesRaw)
$allLibraryRoots = @()
$containing = @()

foreach ($library in $libraries) {
    foreach ($location in @($library.Locations)) {
        if ([string]::IsNullOrWhiteSpace([string]$location)) { continue }
        $locationFull = [System.IO.Path]::GetFullPath([string]$location)
        $allLibraryRoots += $locationFull

        if (Test-InsideRoot -Path $selected.OriginalVideo -Root $locationFull) {
            $containing += [pscustomobject]@{
                Name                  = [string]$library.Name
                Root                  = $locationFull
                EnableRealtimeMonitor = [bool]$library.LibraryOptions.EnableRealtimeMonitor
            }
        }
    }
}

if ($containing.Count -ne 1) {
    throw "Expected selected target to belong to exactly one library location; found $($containing.Count)."
}
if (-not $containing[0].EnableRealtimeMonitor) {
    throw "Containing library does not have realtime monitoring enabled."
}

if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $StagingRoot = [System.IO.Path]::Combine([System.IO.Path]::GetPathRoot($selected.OriginalVideo), "_jellyfin_repair_staging")
}
$StagingRoot = [System.IO.Path]::GetFullPath($StagingRoot)

if (-not [string]::Equals(
        [System.IO.Path]::GetPathRoot($StagingRoot),
        [System.IO.Path]::GetPathRoot($selected.OriginalVideo),
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "StagingRoot must be on the same volume as the selected video so an NTFS hard link can be created."
}

foreach ($root in $allLibraryRoots) {
    if (Test-InsideRoot -Path $StagingRoot -Root $root) {
        throw "StagingRoot is inside a Jellyfin library location: $root"
    }
}

$runFolder = "cross-series-{0}-{1}" -f ($selected.ExpectedKey.ToLowerInvariant()), (Get-Date -Format "yyyyMMdd-HHmmss")
$stagingFolder = [System.IO.Path]::Combine($StagingRoot, $runFolder)
$stagedVideo = [System.IO.Path]::Combine($stagingFolder, [System.IO.Path]::GetFileName($selected.OriginalVideo))
$stagedNfo = [System.IO.Path]::Combine($stagingFolder, [System.IO.Path]::GetFileName($selected.OriginalNfo))

Write-Host ""
Write-Host "=== Selected candidate ==="
Write-Host "Series:          $($selected.SeriesName)"
Write-Host "SeriesId:        $($selected.SeriesId)"
Write-Host "Work:            $($selected.Work)"
Write-Host "OwnerId:         $($selected.OwnerId)"
Write-Host "Owner key:       $($selected.OwnerKey)"
Write-Host "Group sources:   $($selected.SourceCount)"
Write-Host "Group targets:   $($selected.GroupExpectedKeys)"
Write-Host "Target:          $($selected.ExpectedKey)"
Write-Host "Original video:  $($selected.OriginalVideo)"
Write-Host "Original NFO:    $($selected.OriginalNfo)"
Write-Host "Canonical video: $($selected.CanonicalVideo)"
Write-Host "Canonical NFO:   $($selected.CanonicalNfo)"
Write-Host "Library:         $($containing[0].Name)"
Write-Host "Library root:    $($containing[0].Root)"
Write-Host "Realtime:        $($containing[0].EnableRealtimeMonitor)"
Write-Host "Staging root:    $StagingRoot"
Write-Host "2026-01 penalty: $($selected.QuarterPenalty)"
Write-Host ""

if (-not $Apply) {
    Write-Host "DRY RUN finished. No files or Jellyfin data were changed."
    Write-Host ""
    Write-Host "Apply command:"
    Write-Host "  .\experiments\jellyfin12-nfo-refresh\14-cross-series-canonical-hardlink-pilot.ps1 -ApiKey <API_KEY> -Apply"
    return
}

$originalCount = [int]$selected.SourceCount
$reducedCount = $originalCount - 1
$observationResult = "NOT_REACHED"
$cleanupStatus = "NOT_STARTED"
$videoStaged = $false
$nfoStaged = $false
$canonicalVideoCreated = $false
$canonicalNfoCreated = $false
$applyStarted = $false

try {
    if (Test-Path -LiteralPath $stagingFolder) {
        throw "Staging folder already exists unexpectedly: $stagingFolder"
    }

    New-Item -ItemType Directory -Path $stagingFolder -Force | Out-Null
    $applyStarted = $true

    Write-Host ""
    Write-Host "=== Phase 1: remove one hidden original target ==="
    Move-Item -LiteralPath $selected.OriginalNfo -Destination $stagedNfo
    $nfoStaged = $true
    Move-Item -LiteralPath $selected.OriginalVideo -Destination $stagedVideo
    $videoStaged = $true

    $removed = Wait-PathForgotten `
        -OwnerId $selected.OwnerId `
        -Path $selected.OriginalVideo `
        -ExpectedOwnerCount $reducedCount `
        -TimeoutSeconds $RemovalTimeoutSeconds `
        -Label "Original removal"

    if (-not $removed) {
        throw "Original target did not reach the expected removed state."
    }

    Write-Host "Original removal confirmed: owner sources $originalCount -> $reducedCount."

    Write-Host ""
    Write-Host "=== Phase 2: create temporary canonical hardlink ==="

    # Put the canonical NFO in place first so Jellyfin sees the correct metadata
    # when the hard-linked video appears.
    Copy-Item -LiteralPath $stagedNfo -Destination $selected.CanonicalNfo
    $canonicalNfoCreated = $true

    New-Item -ItemType HardLink -Path $selected.CanonicalVideo -Target $stagedVideo | Out-Null
    $canonicalVideoCreated = $true

    if (-not (Test-Path -LiteralPath $selected.CanonicalVideo -PathType Leaf)) {
        throw "Canonical hardlink was not created."
    }
    if ((Get-Item -LiteralPath $selected.CanonicalVideo).Length -ne (Get-Item -LiteralPath $stagedVideo).Length) {
        throw "Canonical hardlink length does not match staged source length."
    }

    Write-Host "Hardlink created. Waiting for Jellyfin to stabilize..."

    $deadline = (Get-Date).AddSeconds($ObservationTimeoutSeconds)
    $lastSignature = ""
    $stableCount = 0
    $stableState = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Get-ObservedState -OwnerId $selected.OwnerId -Path $selected.CanonicalVideo
        $signature = Get-StateSignature -State $state
        Write-Host "Canonical state: $signature"

        if (-not $state.TargetExpanded) {
            $lastSignature = ""
            $stableCount = 0
            continue
        }

        if ($signature -eq $lastSignature) {
            $stableCount += 1
        }
        else {
            $lastSignature = $signature
            $stableCount = 1
        }

        if ($stableCount -ge $StableSamples) {
            $stableState = $state
            break
        }
    }

    Write-Host ""
    Write-Host "=== Observation ==="

    if ($null -eq $stableState) {
        $observationResult = "PARTIAL / OTHER STATE"
        Write-Host "RESULT: $observationResult" -ForegroundColor Yellow
        Write-Host "Canonical item did not reach a stable expanded-visible state before timeout."
    }
    else {
        $seriesVisible = Get-SeriesVisible -SeriesId $selected.SeriesId -Path $selected.CanonicalVideo

        Write-Host "Owner source count:        $($stableState.OwnerSourceCount)"
        Write-Host "Owner contains canonical:  $($stableState.OwnerContainsTarget)"
        Write-Host "Target normally visible:   $($stableState.TargetNormal)"
        Write-Host "Target expanded visible:   $($stableState.TargetExpanded)"
        Write-Host "Target ItemId:              $($stableState.TargetId)"
        Write-Host "Target current key:         $($stableState.TargetKey)"
        Write-Host "Target media-source count:  $($stableState.TargetMediaSources)"
        Write-Host "Target SeriesId:            $($stableState.TargetSeriesId)"
        Write-Host "Target SeasonId:            $($stableState.TargetSeasonId)"
        Write-Host "Visible through Series:     $seriesVisible"
        Write-Host ""

        $independent = (
            $stableState.OwnerFound -and
            $stableState.OwnerSourceCount -eq $reducedCount -and
            -not $stableState.OwnerContainsTarget -and
            $stableState.TargetNormal -and
            $stableState.TargetExpanded -and
            $stableState.TargetKey -eq $selected.ExpectedKey -and
            $stableState.TargetMediaSources -eq 1 -and
            $stableState.TargetSeriesId -eq $selected.SeriesId -and
            $seriesVisible
        )

        $remerged = (
            $stableState.OwnerFound -and
            $stableState.OwnerSourceCount -eq $originalCount -and
            $stableState.OwnerContainsTarget -and
            -not $stableState.TargetNormal -and
            $stableState.TargetExpanded -and
            $stableState.TargetMediaSources -eq $originalCount
        )

        if ($independent) {
            $observationResult = "CANONICAL HARDLINK STAYS INDEPENDENT"
            Write-Host "RESULT: $observationResult" -ForegroundColor Green
        }
        elseif ($remerged) {
            $observationResult = "CANONICAL HARDLINK RE-MERGED"
            Write-Host "RESULT: $observationResult" -ForegroundColor Yellow
        }
        else {
            $observationResult = "PARTIAL / OTHER STATE"
            Write-Host "RESULT: $observationResult" -ForegroundColor Yellow
        }
    }
}
finally {
    if ($Apply -and $applyStarted) {
        Write-Host ""
        Write-Host "=== Cleanup: restore original server layout ==="

        $cleanupFilesOk = $true
        $canonicalForgotten = $false
        $originalGroupRestored = $false

        try {
            if (Test-Path -LiteralPath $selected.CanonicalNfo -PathType Leaf) {
                Remove-Item -LiteralPath $selected.CanonicalNfo -Force
            }
            $canonicalNfoCreated = $false

            if (Test-Path -LiteralPath $selected.CanonicalVideo -PathType Leaf) {
                Remove-Item -LiteralPath $selected.CanonicalVideo -Force
            }
            $canonicalVideoCreated = $false

            $canonicalForgotten = Wait-PathForgotten `
                -OwnerId $selected.OwnerId `
                -Path $selected.CanonicalVideo `
                -ExpectedOwnerCount $reducedCount `
                -TimeoutSeconds $RestoreTimeoutSeconds `
                -Label "Canonical cleanup"

            if (-not $canonicalForgotten) {
                Write-Host "Canonical path was deleted from disk but Jellyfin did not confirm the reduced state before timeout." -ForegroundColor Yellow
            }

            if ($canonicalForgotten) {
                # Restore NFO first so the metadata is already available when the
                # original video path reappears to the realtime monitor.
                if (Test-Path -LiteralPath $stagedNfo -PathType Leaf) {
                    if (Test-Path -LiteralPath $selected.OriginalNfo) {
                        throw "Original NFO path unexpectedly exists during cleanup: $($selected.OriginalNfo)"
                    }
                    Move-Item -LiteralPath $stagedNfo -Destination $selected.OriginalNfo
                    $nfoStaged = $false
                }

                if (Test-Path -LiteralPath $stagedVideo -PathType Leaf) {
                    if (Test-Path -LiteralPath $selected.OriginalVideo) {
                        throw "Original video path unexpectedly exists during cleanup: $($selected.OriginalVideo)"
                    }
                    Move-Item -LiteralPath $stagedVideo -Destination $selected.OriginalVideo
                    $videoStaged = $false
                }

                $restoreDeadline = (Get-Date).AddSeconds($RestoreTimeoutSeconds)
                while ((Get-Date) -lt $restoreDeadline) {
                    Start-Sleep -Seconds $PollIntervalSeconds
                    $restoreState = Get-ObservedState -OwnerId $selected.OwnerId -Path $selected.OriginalVideo
                    Write-Host ("Original restore state: ownerSources={0}, ownerHasPath={1}, normal={2}, expanded={3}, key={4}, sources={5}" -f `
                        $restoreState.OwnerSourceCount,
                        $restoreState.OwnerContainsTarget,
                        $restoreState.TargetNormal,
                        $restoreState.TargetExpanded,
                        $restoreState.TargetKey,
                        $restoreState.TargetMediaSources)

                    if ($restoreState.OwnerFound -and
                        $restoreState.OwnerSourceCount -eq $originalCount -and
                        $restoreState.OwnerContainsTarget -and
                        -not $restoreState.TargetNormal -and
                        $restoreState.TargetExpanded -and
                        $restoreState.TargetKey -eq $selected.ExpectedKey -and
                        $restoreState.TargetMediaSources -eq $originalCount) {
                        $originalGroupRestored = $true
                        break
                    }
                }
            }
        }
        catch {
            $cleanupFilesOk = $false
            Write-Host "CLEANUP ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }

        # Last-resort file restoration if an exception happened before the normal
        # restore path could run. Never overwrite an existing original path.
        if ($nfoStaged -and (Test-Path -LiteralPath $stagedNfo -PathType Leaf) -and -not (Test-Path -LiteralPath $selected.OriginalNfo)) {
            try {
                Move-Item -LiteralPath $stagedNfo -Destination $selected.OriginalNfo
                $nfoStaged = $false
            }
            catch {
                $cleanupFilesOk = $false
                Write-Host "LAST-RESORT NFO RESTORE ERROR: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        if ($videoStaged -and (Test-Path -LiteralPath $stagedVideo -PathType Leaf) -and -not (Test-Path -LiteralPath $selected.OriginalVideo)) {
            try {
                Move-Item -LiteralPath $stagedVideo -Destination $selected.OriginalVideo
                $videoStaged = $false
            }
            catch {
                $cleanupFilesOk = $false
                Write-Host "LAST-RESORT VIDEO RESTORE ERROR: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        $originalFilesPresent = (
            (Test-Path -LiteralPath $selected.OriginalVideo -PathType Leaf) -and
            (Test-Path -LiteralPath $selected.OriginalNfo -PathType Leaf)
        )
        $canonicalFilesAbsent = (
            -not (Test-Path -LiteralPath $selected.CanonicalVideo) -and
            -not (Test-Path -LiteralPath $selected.CanonicalNfo)
        )

        if (Test-Path -LiteralPath $stagingFolder -PathType Container) {
            $remaining = @(Get-ChildItem -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue
            }
        }

        if ($cleanupFilesOk -and $originalFilesPresent -and $canonicalFilesAbsent -and $originalGroupRestored) {
            $cleanupStatus = "RESTORED"
            Write-Host "RESTORE RESULT: original files and original Jellyfin group restored." -ForegroundColor Green
        }
        elseif ($originalFilesPresent -and $canonicalFilesAbsent) {
            $cleanupStatus = "FILES_RESTORED_JELLYFIN_NOT_CONFIRMED"
            Write-Host "RESTORE RESULT: original files restored, but Jellyfin group restoration was not confirmed." -ForegroundColor Yellow
        }
        else {
            $cleanupStatus = "INCOMPLETE"
            Write-Host "RESTORE RESULT: INCOMPLETE. Do not rerun; inspect the paths printed above." -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Observation result: $observationResult"
        Write-Host "Cleanup status:     $cleanupStatus"
        Write-Host "No SQLite writes and no metadata FullRefresh were performed."
    }
}
