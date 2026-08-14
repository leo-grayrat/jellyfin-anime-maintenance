[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",
    [string]$Root = "D:\Resource\BangumiLink",
    [string]$ProductionRoot = "D:\Bangumi",
    [int]$ExpectedVideoCount = 676,
    [int]$ExpectedTargetCount = 243,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')
$Root = [System.IO.Path]::GetFullPath($Root)
$ProductionRoot = [System.IO.Path]::GetFullPath($ProductionRoot)
$ViewRoot = [System.IO.Path]::Combine($Root, "View")
$TempRoot = [System.IO.Path]::Combine($Root, "Temp")
$LogsRoot = [System.IO.Path]::Combine($Root, "Logs")
$Phase1ManifestPath = [System.IO.Path]::Combine($LogsRoot, "manifest.csv")
$FullManifestPath = [System.IO.Path]::Combine($LogsRoot, "full-manifest-v2.csv")

$canonicalCommon = Join-Path $PSScriptRoot "lib\canonical_view_common.ps1"
$auditCommon = Join-Path $PSScriptRoot "lib\tv_audit_common.ps1"
$fullCommon = Join-Path $PSScriptRoot "lib\full_canonical_view_common.ps1"
$applyCommon = Join-Path $PSScriptRoot "lib\full_canonical_view_apply.ps1"
foreach ($helper in @($canonicalCommon, $auditCommon, $fullCommon, $applyCommon)) {
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "Required helper not found: $helper"
    }
}
. $canonicalCommon
. $auditCommon
. $fullCommon
. $applyCommon

$Headers = @{
    Authorization = "MediaBrowser Client=`"full-canonical-view-builder`", Device=`"PowerShell`", DeviceId=`"full-canonical-view-builder`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-FcvJfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-FcvCsvRowsIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Import-Csv -LiteralPath $Path)
}

function Get-FcvProductionLocations {
    param([Parameter(Mandatory = $true)]$VirtualFolders)

    $locations = @()
    $seen = @{}
    foreach ($library in @(Get-TvaTvLibraries -VirtualFolders $VirtualFolders)) {
        foreach ($locationValue in @($library.Locations)) {
            $location = [string]$locationValue
            if ([string]::IsNullOrWhiteSpace($location)) { continue }
            $fullLocation = [System.IO.Path]::GetFullPath($location)
            if (-not (Test-FcvPathUnderOrEqual -Path $fullLocation -Root $ProductionRoot)) { continue }
            $key = ([string]$library.Name).ToLowerInvariant() + "|" + (Get-CvPathKey -Path $fullLocation)
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $locations += [pscustomobject]@{ LibraryName = [string]$library.Name; Root = $fullLocation }
        }
    }
    if ($locations.Count -eq 0) {
        throw "No production tvshows library location was found under $ProductionRoot"
    }
    for ($i = 0; $i -lt $locations.Count; $i++) {
        for ($j = $i + 1; $j -lt $locations.Count; $j++) {
            $a = [string]$locations[$i].Root
            $b = [string]$locations[$j].Root
            if ((Test-FcvPathUnderOrEqual -Path $a -Root $b) -or (Test-FcvPathUnderOrEqual -Path $b -Root $a)) {
                throw "Selected production library roots overlap: $a :: $b"
            }
        }
    }
    return @($locations | Sort-Object LibraryName, Root)
}

function New-FcvManifestRowFromPlan {
    param($PlanRow, [string]$BuildId, [string]$Status)
    return [pscustomobject]@{
        SourcePath = [string]$PlanRow.SourcePath
        CanonicalPath = [string]$PlanRow.CanonicalPath
        LibraryName = [string]$PlanRow.LibraryName
        Role = [string]$PlanRow.Role
        Operation = [string]$PlanRow.Operation
        SourceLength = [long]$PlanRow.SourceLength
        ExpectedKey = [string]$PlanRow.ExpectedKey
        BuildId = $BuildId
        Status = $Status
    }
}

function Get-FcvPhase1SeedRows {
    param([object[]]$Phase1Rows = @(), [object[]]$Plan)

    if ($Phase1Rows.Count -eq 0) { return @() }
    if ($Phase1Rows.Count -ne $ExpectedTargetCount) {
        throw "Phase 1 manifest must contain exactly $ExpectedTargetCount rows when present; found $($Phase1Rows.Count)."
    }
    $planBySource = @{}
    foreach ($row in $Plan) { $planBySource[(Get-CvPathKey -Path ([string]$row.SourcePath))] = $row }

    $seedRows = @()
    foreach ($oldRow in $Phase1Rows) {
        foreach ($mapping in @(
            [pscustomobject]@{ Source = [string]$oldRow.OriginalVideo; Canonical = [string]$oldRow.CanonicalVideo; Role = "CORRECTION_VIDEO" },
            [pscustomobject]@{ Source = [string]$oldRow.OriginalNfo; Canonical = [string]$oldRow.CanonicalNfo; Role = "CORRECTION_SIDECAR" }
        )) {
            if ([string]::IsNullOrWhiteSpace($mapping.Source)) { throw "Phase 1 manifest source path is empty." }
            $sourceKey = Get-CvPathKey -Path $mapping.Source
            if (-not $planBySource.ContainsKey($sourceKey)) {
                throw "Phase 1 manifest source is absent from full plan: $($mapping.Source)"
            }
            $planRow = $planBySource[$sourceKey]
            if ([string]$planRow.Role -ne [string]$mapping.Role) {
                throw "Phase 1 manifest role does not match full plan: $($mapping.Source)"
            }
            if ((Get-CvPathKey -Path $mapping.Canonical) -ne (Get-CvPathKey -Path ([string]$planRow.CanonicalPath))) {
                throw "Phase 1 canonical path does not match full plan: $($mapping.Canonical)"
            }
            $seedRows += New-FcvManifestRowFromPlan -PlanRow $planRow -BuildId ("phase1-" + [string]$oldRow.BuildId) -Status "PHASE1"
        }
    }
    return @($seedRows)
}

function Invoke-FcvPreflight {
    $systemInfo = Invoke-FcvJfGet -Uri "$Server/System/Info"
    $virtualFolders = Invoke-FcvJfGet -Uri "$Server/Library/VirtualFolders"
    $locations = @(Get-FcvProductionLocations -VirtualFolders $virtualFolders)
    Assert-FcvDisjointRoots -SourceRoots @($locations | ForEach-Object { [string]$_.Root }) -ViewRoot $ViewRoot

    $sourceFiles = @()
    foreach ($location in $locations) {
        $sourceFiles += @(Get-FcvSourceFiles -LibraryName ([string]$location.LibraryName) -LibraryRoot ([string]$location.Root))
    }
    $sourceIndex = @{}
    foreach ($source in $sourceFiles) {
        $key = Get-CvPathKey -Path ([string]$source.Path)
        if ($sourceIndex.ContainsKey($key)) { throw "Duplicate production source path: $($source.Path)" }
        $sourceIndex[$key] = $source
    }

    $sourceVideos = @($sourceFiles | Where-Object { Test-FcvVideoPath -Path ([string]$_.Path) })
    if ($sourceVideos.Count -ne $ExpectedVideoCount) {
        throw "Expected exactly $ExpectedVideoCount production TV videos, found $($sourceVideos.Count)."
    }

    $targets = @(Get-CvCorrectionTargets -CsvPath $RunLogPath -ExpectedCount $ExpectedTargetCount)
    foreach ($target in $targets) {
        $targetPath = [System.IO.Path]::GetFullPath([string]$target.VideoPath)
        if (-not $sourceIndex.ContainsKey((Get-CvPathKey -Path $targetPath))) {
            throw "Correction target is absent from production inventory: $targetPath"
        }
        $nfoPath = [System.IO.Path]::ChangeExtension($targetPath, ".nfo")
        if (-not (Test-CvNativeFile -Path $nfoPath)) { throw "Correction target NFO is missing: $nfoPath" }
        $identity = Get-CvNfoIdentity -NfoPath $nfoPath
        if ([int]$identity.Season -ne [int]$target.TargetSeason -or [int]$identity.Episode -ne [int]$target.TargetEpisode) {
            throw "Correction NFO identity mismatch for $targetPath"
        }
    }

    $plan = @(New-FcvPlan -SourceFiles $sourceFiles -Targets $targets -ViewRoot $ViewRoot)
    if ($plan.Count -ne $sourceFiles.Count) {
        throw "Full plan is not one-to-one with source inventory: source=$($sourceFiles.Count) plan=$($plan.Count)"
    }
    foreach ($row in $plan) {
        if ([string]$row.Operation -eq "HARDLINK") {
            if ((Get-CvVolumeRoot -Path ([string]$row.SourcePath)) -ne (Get-CvVolumeRoot -Path ([string]$row.CanonicalPath))) {
                throw "Hardlink plan crosses volumes: $($row.SourcePath)"
            }
        }
    }

    $phase1Rows = @(Get-FcvCsvRowsIfPresent -Path $Phase1ManifestPath)
    $phase1Seeds = @(Get-FcvPhase1SeedRows -Phase1Rows $phase1Rows -Plan $plan)
    $fullRows = @(Get-FcvCsvRowsIfPresent -Path $FullManifestPath)
    $effectiveRows = @(Merge-FcvManifestRows -ExistingRows $phase1Seeds -NewRows $fullRows)
    $effectiveIndex = Get-FcvManifestIndex -Rows $effectiveRows

    $planCanonicalIndex = @{}
    foreach ($row in $plan) { $planCanonicalIndex[(Get-CvPathKey -Path ([string]$row.CanonicalPath))] = $row }
    foreach ($row in $fullRows) {
        if (-not $planCanonicalIndex.ContainsKey((Get-CvPathKey -Path ([string]$row.CanonicalPath)))) {
            throw "Full manifest contains a stale path: $($row.CanonicalPath)"
        }
    }

    if (Test-CvNativeDirectory -Path $ViewRoot) {
        foreach ($viewFile in @(Get-FcvSourceFiles -LibraryName "__VIEW__" -LibraryRoot $ViewRoot)) {
            $viewKey = Get-CvPathKey -Path ([string]$viewFile.Path)
            if (-not $effectiveIndex.ContainsKey($viewKey)) { throw "View contains an unmanaged file: $($viewFile.Path)" }
            if (-not $planCanonicalIndex.ContainsKey($viewKey)) { throw "View contains a stale managed file: $($viewFile.Path)" }
        }
    }

    $conflicts = @()
    foreach ($row in $plan) {
        $existing = Test-FcvExistingTarget -TargetPath ([string]$row.CanonicalPath) -SourcePath ([string]$row.SourcePath) -ExpectedLength ([long]$row.SourceLength) -ManifestIndex $effectiveIndex
        $row.State = [string]$existing.State
        if ($row.State -eq "CONFLICT") { $conflicts += "$($row.CanonicalPath) :: $($existing.Reason)" }
    }
    if ($conflicts.Count -gt 0) {
        throw "Full canonical preflight found $($conflicts.Count) conflict(s): $((@($conflicts | Select-Object -First 10)) -join ' | ')"
    }

    return [pscustomobject]@{
        SystemInfo = $systemInfo
        Locations = @($locations)
        SourceFiles = @($sourceFiles)
        SourceVideos = @($sourceVideos)
        Targets = @($targets)
        Plan = @($plan)
        FullManifestRows = @($fullRows)
    }
}

function Write-FcvPreflightSummary {
    param($Result)
    $plan = @($Result.Plan)
    Write-Host ""
    Write-Host "=== Full Canonical View Preflight ==="
    Write-Host ("Server version:       {0}" -f [string]$Result.SystemInfo.Version)
    Write-Host ("Production roots:     {0}" -f @($Result.Locations).Count)
    Write-Host ("Source files:         {0}" -f @($Result.SourceFiles).Count)
    Write-Host ("Source videos:        {0}" -f @($Result.SourceVideos).Count)
    Write-Host ("Correction targets:   {0}" -f @($Result.Targets).Count)
    Write-Host ("Correction videos:    {0}" -f @($plan | Where-Object { $_.Role -eq "CORRECTION_VIDEO" }).Count)
    Write-Host ("Correction sidecars:  {0}" -f @($plan | Where-Object { $_.Role -eq "CORRECTION_SIDECAR" }).Count)
    Write-Host ("Passthrough videos:   {0}" -f @($plan | Where-Object { $_.Role -eq "PASSTHROUGH_VIDEO" }).Count)
    Write-Host ("Passthrough files:    {0}" -f @($plan | Where-Object { $_.Role -eq "PASSTHROUGH_FILE" }).Count)
    Write-Host ("Hardlink rows:        {0}" -f @($plan | Where-Object { $_.Operation -eq "HARDLINK" }).Count)
    Write-Host ("Copy rows:            {0}" -f @($plan | Where-Object { $_.Operation -eq "COPY" }).Count)
    Write-Host ("Reusable rows:        {0}" -f @($plan | Where-Object { $_.State -eq "REUSABLE" }).Count)
    Write-Host ("Rows to create:       {0}" -f @($plan | Where-Object { $_.State -eq "MISSING" }).Count)
    Write-Host "Preflight failures:   0"
}

Write-Host ""
Write-Host "=== Jellyfin Full Canonical View Builder ==="
if ($Apply) { Write-Host "Mode: APPLY" } else { Write-Host "Mode: DRY RUN" }
Write-Host "Production root: $ProductionRoot"
Write-Host "View root: $ViewRoot"

$preflight = Invoke-FcvPreflight
Write-FcvPreflightSummary -Result $preflight

Write-Host ""
Write-Host "Sample mappings:"
foreach ($row in @($preflight.Plan | Select-Object -First 10)) {
    Write-Host ("- [{0}] {1} -> {2}" -f [string]$row.Role, [string]$row.SourcePath, [string]$row.CanonicalPath)
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN finished. No files were written."
    exit 0
}

Write-Host ""
Write-Host "Re-running full preflight before Apply..."
$preflight = Invoke-FcvPreflight
Write-FcvPreflightSummary -Result $preflight

$applyResult = Invoke-FcvApplyBuild `
    -Preflight $preflight `
    -Root $Root `
    -ViewRoot $ViewRoot `
    -TempRoot $TempRoot `
    -LogsRoot $LogsRoot `
    -FullManifestPath $FullManifestPath

Write-Host ""
Write-Host "=== Full View Apply complete ==="
Write-Host ("Build id:            {0}" -f [string]$applyResult.BuildId)
Write-Host ("Plan rows:           {0}" -f [int]$applyResult.PlanCount)
Write-Host ("Created rows:        {0}" -f [int]$applyResult.CreatedCount)
Write-Host ("Reused rows:         {0}" -f [int]$applyResult.ReusedCount)
Write-Host ("Manifest:            {0}" -f [string]$applyResult.ManifestPath)
Write-Host ("Build log:           {0}" -f [string]$applyResult.BuildLogPath)
Write-Host "Source files were not renamed, moved, overwritten, or deleted."
Write-Host "Jellyfin production library roots were not changed."
