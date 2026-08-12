[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",

    [string]$Root = "D:\Resource\BangumiLink",

    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')
$ExpectedTargetCount = 243

$commonPath = Join-Path $PSScriptRoot "lib\canonical_view_common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Canonical view helper library not found: $commonPath"
}
. $commonPath

$Root = [System.IO.Path]::GetFullPath($Root)
$ViewRoot = [System.IO.Path]::Combine($Root, "View")
$TempRoot = [System.IO.Path]::Combine($Root, "Temp")
$LogsRoot = [System.IO.Path]::Combine($Root, "Logs")
$ManifestPath = [System.IO.Path]::Combine($LogsRoot, "manifest.csv")

$Headers = @{
    Authorization = "MediaBrowser Client=`"canonical-view-builder`", Device=`"PowerShell`", DeviceId=`"canonical-view-builder`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-CvJfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-CvLibraryLocations {
    param([Parameter(Mandatory = $true)]$VirtualFolders)

    $locations = @()
    foreach ($library in @($VirtualFolders)) {
        foreach ($location in @($library.Locations)) {
            if ([string]::IsNullOrWhiteSpace([string]$location)) { continue }
            $locations += [pscustomobject]@{
                LibraryName = [string]$library.Name
                Root        = [System.IO.Path]::GetFullPath([string]$location)
            }
        }
    }
    return @($locations)
}

function Get-CvContainingLibrary {
    param(
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [Parameter(Mandatory = $true)][object[]]$Locations
    )

    $sourceDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($VideoPath))
    if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
        throw "Video path has no parent directory: $VideoPath"
    }

    $matches = @()
    foreach ($location in $Locations) {
        try {
            $relative = Get-CvRelativeDirectory -SourceDirectory $sourceDirectory -LibraryRoot $location.Root
            $matches += [pscustomobject]@{
                LibraryName      = $location.LibraryName
                Root             = $location.Root
                RelativeDirectory = $relative
                RootLength       = ([System.IO.Path]::GetFullPath($location.Root)).Length
            }
        }
        catch {
            # Not inside this location.
        }
    }

    if ($matches.Count -eq 0) {
        throw "Video does not belong to any Jellyfin library location: $VideoPath"
    }

    $ordered = @($matches | Sort-Object RootLength -Descending, LibraryName, Root)
    $bestLength = [int]$ordered[0].RootLength
    $best = @($ordered | Where-Object { [int]$_.RootLength -eq $bestLength })

    if ($best.Count -ne 1) {
        $roots = ($best | ForEach-Object { "$($_.LibraryName):$($_.Root)" }) -join "; "
        throw "Video matches multiple equally specific Jellyfin library locations: $roots"
    }

    return $best[0]
}

function Get-CvExistingManifestRows {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return @()
    }
    return @(Import-Csv -LiteralPath $ManifestPath)
}

function New-CvFailure {
    param(
        [string]$VideoPath,
        [string]$Stage,
        [string]$Message
    )

    return [pscustomobject]@{
        VideoPath = $VideoPath
        Stage     = $Stage
        Message   = $Message
    }
}

Write-Host ""
Write-Host "=== Jellyfin Canonical View Builder ==="
if ($Apply) { Write-Host "Mode: APPLY (preflight only in this checkpoint)" } else { Write-Host "Mode: DRY RUN" }
Write-Host "Root: $Root"
Write-Host ""

$systemInfo = Invoke-CvJfGet -Uri "$Server/System/Info"
Write-Host "Server version: $($systemInfo.Version)"

$virtualFolders = @(Invoke-CvJfGet -Uri "$Server/Library/VirtualFolders")
$libraryLocations = @(Get-CvLibraryLocations -VirtualFolders $virtualFolders)
if ($libraryLocations.Count -eq 0) {
    throw "No Jellyfin library locations were returned."
}

$targets = @(Get-CvCorrectionTargets -CsvPath $RunLogPath -ExpectedCount $ExpectedTargetCount)
Write-Host "Correction targets: $($targets.Count)"

$manifestRows = @(Get-CvExistingManifestRows)
$manifestIndex = Get-CvManifestIndex -Rows $manifestRows
if ($manifestRows.Count -gt 0) {
    Write-Host "Existing manifest rows: $($manifestRows.Count)"
}
else {
    Write-Host "Existing manifest rows: 0"
}

$plan = @()
$failures = @()
$canonicalPathOwners = @{}

foreach ($target in $targets) {
    $videoPath = [System.IO.Path]::GetFullPath([string]$target.VideoPath)
    $nfoPath = [System.IO.Path]::ChangeExtension($videoPath, ".nfo")

    try {
        if (-not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
            throw "Source video not found."
        }
        if (-not (Test-Path -LiteralPath $nfoPath -PathType Leaf)) {
            throw "Source NFO not found: $nfoPath"
        }

        $identity = Get-CvNfoIdentity -NfoPath $nfoPath
        if ([int]$identity.Season -ne [int]$target.TargetSeason -or [int]$identity.Episode -ne [int]$target.TargetEpisode) {
            throw "NFO identity does not match correction target $($target.ExpectedKey): found $(Get-CvEpisodeKey -Season $identity.Season -Episode $identity.Episode)."
        }

        $library = Get-CvContainingLibrary -VideoPath $videoPath -Locations $libraryLocations
        $canonical = Get-CvCanonicalPaths `
            -ViewRoot $ViewRoot `
            -LibraryName $library.LibraryName `
            -RelativeDirectory $library.RelativeDirectory `
            -VideoPath $videoPath `
            -NfoPath $nfoPath `
            -ExpectedKey $target.ExpectedKey

        $sourceRoot = [System.IO.Path]::GetPathRoot($videoPath)
        $viewDriveRoot = [System.IO.Path]::GetPathRoot($canonical.Video)
        if (-not [string]::Equals($sourceRoot, $viewDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Source and canonical view are on different volumes: source=$sourceRoot view=$viewDriveRoot"
        }

        foreach ($candidatePath in @($canonical.Video, $canonical.Nfo)) {
            $candidateKey = Get-CvPathKey -Path $candidatePath
            if ($canonicalPathOwners.ContainsKey($candidateKey)) {
                throw "Canonical target path collides with another correction target: $candidatePath"
            }
            $canonicalPathOwners[$candidateKey] = $videoPath
        }

        $videoLength = [long](Get-Item -LiteralPath $videoPath).Length
        $videoExisting = Test-CvExistingTarget `
            -TargetPath $canonical.Video `
            -SourcePath $videoPath `
            -ManifestIndex $manifestIndex `
            -ManifestSourceColumn "OriginalVideo" `
            -ExpectedLength $videoLength

        $nfoExisting = Test-CvExistingTarget `
            -TargetPath $canonical.Nfo `
            -SourcePath $nfoPath `
            -ManifestIndex $manifestIndex `
            -ManifestSourceColumn "OriginalNfo"

        if ($videoExisting.State -eq "CONFLICT") {
            throw "Canonical video conflict: $($videoExisting.Reason) :: $($canonical.Video)"
        }
        if ($nfoExisting.State -eq "CONFLICT") {
            throw "Canonical NFO conflict: $($nfoExisting.Reason) :: $($canonical.Nfo)"
        }

        $plan += [pscustomobject]@{
            Work              = [string]$target.Work
            LibraryName       = [string]$library.LibraryName
            LibraryRoot       = [string]$library.Root
            RelativeDirectory = [string]$library.RelativeDirectory
            OriginalVideo     = $videoPath
            OriginalNfo       = $nfoPath
            ExpectedSeason    = [int]$target.TargetSeason
            ExpectedEpisode   = [int]$target.TargetEpisode
            ExpectedKey       = [string]$target.ExpectedKey
            CanonicalVideo    = [string]$canonical.Video
            CanonicalNfo      = [string]$canonical.Nfo
            VideoLength       = $videoLength
            VideoState        = [string]$videoExisting.State
            NfoState          = [string]$nfoExisting.State
        }
    }
    catch {
        $failures += New-CvFailure -VideoPath $videoPath -Stage "PREFLIGHT" -Message $_.Exception.Message
    }
}

$plannedCount = $plan.Count
$videoReusable = @($plan | Where-Object { $_.VideoState -eq "REUSABLE" }).Count
$videoCreate = @($plan | Where-Object { $_.VideoState -eq "MISSING" }).Count
$nfoReusable = @($plan | Where-Object { $_.NfoState -eq "REUSABLE" }).Count
$nfoCreate = @($plan | Where-Object { $_.NfoState -eq "MISSING" }).Count

Write-Host ""
Write-Host "=== Preflight summary ==="
Write-Host "Planned targets:      $plannedCount"
Write-Host "Preflight failures:   $($failures.Count)"
Write-Host "Videos reusable:      $videoReusable"
Write-Host "Videos to create:     $videoCreate"
Write-Host "NFOs reusable:        $nfoReusable"
Write-Host "NFOs to create:       $nfoCreate"

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "First preflight failures:"
    foreach ($failure in @($failures | Select-Object -First 20)) {
        Write-Host "- $($failure.VideoPath) :: $($failure.Message)"
    }
    throw "Canonical view preflight failed for $($failures.Count) target(s). No files were written."
}

if ($plannedCount -ne $ExpectedTargetCount) {
    throw "Preflight did not produce exactly $ExpectedTargetCount plan rows. No files were written."
}

Write-Host ""
Write-Host "Sample mappings:"
foreach ($row in @($plan | Select-Object -First 8)) {
    Write-Host "- $($row.ExpectedKey) :: $($row.OriginalVideo)"
    Write-Host "  -> $($row.CanonicalVideo)"
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN finished. No files were written."
    exit 0
}

Write-Host ""
throw "Apply phase is intentionally not enabled until this 243-target preflight is verified on the real server. No files were written."
