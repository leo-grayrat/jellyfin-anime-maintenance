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
                LibraryName       = $location.LibraryName
                Root              = $location.Root
                RelativeDirectory = $relative
                RootLength        = ([System.IO.Path]::GetFullPath($location.Root)).Length
            }
        }
        catch {
            # Not inside this location.
        }
    }

    if ($matches.Count -eq 0) {
        throw "Video does not belong to any Jellyfin library location: $VideoPath"
    }

    $sortProperties = @(
        @{ Expression = { $_.RootLength }; Descending = $true },
        @{ Expression = { $_.LibraryName }; Descending = $false },
        @{ Expression = { $_.Root }; Descending = $false }
    )
    $ordered = @($matches | Sort-Object -Property $sortProperties)
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

function New-CvBuildResult {
    param(
        [Parameter(Mandatory = $true)]$PlanRow,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [string]$VideoResult = "PENDING",
        [string]$NfoResult = "PENDING",
        [string]$Status = "PENDING",
        [string]$ErrorMessage = ""
    )

    return [pscustomobject]@{
        BuildId          = $BuildId
        Work             = [string]$PlanRow.Work
        LibraryName      = [string]$PlanRow.LibraryName
        ExpectedKey      = [string]$PlanRow.ExpectedKey
        OriginalVideo    = [string]$PlanRow.OriginalVideo
        OriginalNfo      = [string]$PlanRow.OriginalNfo
        CanonicalVideo   = [string]$PlanRow.CanonicalVideo
        CanonicalNfo     = [string]$PlanRow.CanonicalNfo
        VideoResult      = $VideoResult
        NfoResult        = $NfoResult
        Status           = $Status
        Error            = $ErrorMessage
        RollbackStatus   = "NOT_NEEDED"
    }
}

Write-Host ""
Write-Host "=== Jellyfin Canonical View Builder ==="
if ($Apply) { Write-Host "Mode: APPLY" } else { Write-Host "Mode: DRY RUN" }
Write-Host "Root: $Root"
Write-Host ""

$systemInfo = Invoke-CvJfGet -Uri "$Server/System/Info"
Write-Host "Server version: $($systemInfo.Version)"

$virtualFolders = @(Invoke-CvJfGet -Uri "$Server/Library/VirtualFolders")
$libraryLocations = @(Get-CvLibraryLocations -VirtualFolders $virtualFolders)
if ($libraryLocations.Count -eq 0) {
    throw "No Jellyfin library locations were returned."
}
Write-Host "Library locations: $($libraryLocations.Count)"

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

        $sourceRoot = Get-CvVolumeRoot -Path $videoPath
        $viewDriveRoot = Get-CvVolumeRoot -Path $canonical.Video
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
            CanonicalDirectory = [string]$canonical.Directory
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
    Write-Host "- [$($row.LibraryName)] $($row.ExpectedKey) :: $($row.OriginalVideo)"
    Write-Host "  -> $($row.CanonicalVideo)"
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN finished. No files were written."
    exit 0
}

$BuildId = Get-Date -Format "yyyyMMdd-HHmmssfff"
$BuildTemp = [System.IO.Path]::Combine($TempRoot, "build-$BuildId")
$BuildLogPath = [System.IO.Path]::Combine($LogsRoot, "build-$BuildId.csv")
$PlanPath = [System.IO.Path]::Combine($BuildTemp, "plan.csv")
$ManifestTempPath = [System.IO.Path]::Combine($BuildTemp, "manifest.csv")
$BuildLogTempPath = [System.IO.Path]::Combine($BuildTemp, "build.csv")

Write-Host ""
Write-Host "=== Apply ==="
Write-Host "Build id: $BuildId"
Write-Host "View root: $ViewRoot"
Write-Host "Temp: $BuildTemp"
Write-Host "Log: $BuildLogPath"

Initialize-CvNativeHardLink
New-CvNativeDirectoryTree -Path $Root | Out-Null
New-CvNativeDirectoryTree -Path $ViewRoot | Out-Null
New-CvNativeDirectoryTree -Path $TempRoot | Out-Null
New-CvNativeDirectoryTree -Path $LogsRoot | Out-Null
New-CvNativeDirectoryTree -Path $BuildTemp | Out-Null

$plan | Export-Csv -LiteralPath $PlanPath -NoTypeInformation -Encoding UTF8

$buildRows = New-Object System.Collections.ArrayList
$createdViewDirectories = New-Object System.Collections.ArrayList
$createdDirectoryKeys = @{}
$manifestCommitted = $false
$rollbackErrors = New-Object System.Collections.ArrayList

try {
    $rowNumber = 0
    foreach ($row in $plan) {
        $rowNumber++
        $videoResult = "PENDING"
        $nfoResult = "PENDING"
        $buildRow = $null

        try {
            $newDirectories = @(New-CvNativeDirectoryTree -Path $row.CanonicalDirectory)
            foreach ($directory in $newDirectories) {
                $directoryKey = Get-CvPathKey -Path $directory
                $viewKey = Get-CvPathKey -Path $ViewRoot
                if ($directoryKey.StartsWith($viewKey + '\', [System.StringComparison]::OrdinalIgnoreCase) -and -not $createdDirectoryKeys.ContainsKey($directoryKey)) {
                    [void]$createdViewDirectories.Add($directory)
                    $createdDirectoryKeys[$directoryKey] = $true
                }
            }

            if ($row.VideoState -eq "MISSING") {
                New-CvNativeHardLink -Path $row.CanonicalVideo -Target $row.OriginalVideo | Out-Null
                $videoResult = "CREATED"
            }
            else {
                $videoResult = "REUSED"
            }

            if (-not (Test-CvNativeFile -Path $row.CanonicalVideo)) {
                throw "Canonical video is not visible after build step: $($row.CanonicalVideo)"
            }
            $canonicalVideoLength = Get-CvNativeFileLength -Path $row.CanonicalVideo
            if ([long]$canonicalVideoLength -ne [long]$row.VideoLength) {
                throw "Canonical video length mismatch after build step: $($row.CanonicalVideo)"
            }

            if ($row.NfoState -eq "MISSING") {
                Copy-CvNativeFile -Source $row.OriginalNfo -Destination $row.CanonicalNfo
                $nfoResult = "CREATED"
            }
            else {
                $nfoResult = "REUSED"
            }

            if (-not (Test-CvNativeFile -Path $row.CanonicalNfo)) {
                throw "Canonical NFO is not visible after build step: $($row.CanonicalNfo)"
            }

            $buildRow = New-CvBuildResult `
                -PlanRow $row `
                -BuildId $BuildId `
                -VideoResult $videoResult `
                -NfoResult $nfoResult `
                -Status "READY"
            [void]$buildRows.Add($buildRow)

            if (($rowNumber % 25) -eq 0 -or $rowNumber -eq $plannedCount) {
                Write-Host "Ready: $rowNumber / $plannedCount"
            }
        }
        catch {
            $buildRow = New-CvBuildResult `
                -PlanRow $row `
                -BuildId $BuildId `
                -VideoResult $videoResult `
                -NfoResult $nfoResult `
                -Status "FAILED" `
                -ErrorMessage $_.Exception.Message
            [void]$buildRows.Add($buildRow)
            throw
        }
    }

    $newManifestRows = @()
    foreach ($row in $plan) {
        $newManifestRows += [pscustomobject]@{
            Work            = [string]$row.Work
            LibraryName     = [string]$row.LibraryName
            OriginalVideo   = [string]$row.OriginalVideo
            OriginalNfo     = [string]$row.OriginalNfo
            ExpectedSeason  = [int]$row.ExpectedSeason
            ExpectedEpisode = [int]$row.ExpectedEpisode
            ExpectedKey     = [string]$row.ExpectedKey
            CanonicalVideo  = [string]$row.CanonicalVideo
            CanonicalNfo    = [string]$row.CanonicalNfo
            VideoLength     = [long]$row.VideoLength
            BuildId         = $BuildId
            Status          = "READY"
        }
    }

    $mergedManifestRows = @(Merge-CvManifestRows -ExistingRows $manifestRows -NewRows $newManifestRows)
    $mergedManifestRows | Export-Csv -LiteralPath $ManifestTempPath -NoTypeInformation -Encoding UTF8
    @($buildRows) | Export-Csv -LiteralPath $BuildLogTempPath -NoTypeInformation -Encoding UTF8

    Move-CvNativeFileReplace -Source $BuildLogTempPath -Destination $BuildLogPath
    Move-CvNativeFileReplace -Source $ManifestTempPath -Destination $ManifestPath
    $manifestCommitted = $true
}
catch {
    $applyError = $_.Exception.Message
    Write-Host ""
    Write-Host "Apply failed: $applyError"
    Write-Host "Rollback: removing only files created by this build..."

    $rollbackPaths = @(Get-CvRollbackPaths -BuildRows @($buildRows))
    foreach ($path in $rollbackPaths) {
        try {
            Remove-CvNativeFile -Path $path
        }
        catch {
            [void]$rollbackErrors.Add("file=$path :: $($_.Exception.Message)")
        }
    }

    $directorySort = @(
        @{ Expression = { ([string]$_).Length }; Descending = $true },
        @{ Expression = { [string]$_ }; Descending = $true }
    )
    foreach ($directory in @($createdViewDirectories | Sort-Object -Property $directorySort)) {
        try {
            [void](Remove-CvNativeDirectoryIfEmpty -Path $directory)
        }
        catch {
            [void]$rollbackErrors.Add("directory=$directory :: $($_.Exception.Message)")
        }
    }

    foreach ($result in @($buildRows)) {
        if ($result.VideoResult -eq "CREATED" -or $result.NfoResult -eq "CREATED") {
            $result.RollbackStatus = if ($rollbackErrors.Count -eq 0) { "ROLLED_BACK" } else { "ROLLBACK_ATTEMPTED" }
        }
        else {
            $result.RollbackStatus = "UNCHANGED"
        }
    }

    try {
        if ($buildRows.Count -gt 0) {
            @($buildRows) | Export-Csv -LiteralPath $BuildLogPath -NoTypeInformation -Encoding UTF8
        }
    }
    catch {
        [void]$rollbackErrors.Add("failure log=$BuildLogPath :: $($_.Exception.Message)")
    }

    if ($rollbackErrors.Count -gt 0) {
        Write-Host "Rollback encountered $($rollbackErrors.Count) error(s):"
        foreach ($rollbackError in $rollbackErrors) {
            Write-Host "- $rollbackError"
        }
        throw "Apply failed and rollback was incomplete. Original error: $applyError. Inspect $BuildTemp and $BuildLogPath before retrying."
    }

    throw "Apply failed. Files created by this build were rolled back. Original media was not changed. Details: $applyError. Build temp kept at $BuildTemp"
}

if (-not $manifestCommitted) {
    throw "Internal error: Apply finished without committing the manifest."
}

$videosReady = @($buildRows | Where-Object { $_.VideoResult -eq "CREATED" -or $_.VideoResult -eq "REUSED" }).Count
$nfosReady = @($buildRows | Where-Object { $_.NfoResult -eq "CREATED" -or $_.NfoResult -eq "REUSED" }).Count
$videosCreated = @($buildRows | Where-Object { $_.VideoResult -eq "CREATED" }).Count
$videosReused = @($buildRows | Where-Object { $_.VideoResult -eq "REUSED" }).Count
$nfosCreated = @($buildRows | Where-Object { $_.NfoResult -eq "CREATED" }).Count
$nfosReused = @($buildRows | Where-Object { $_.NfoResult -eq "REUSED" }).Count

try {
    if (Test-Path -LiteralPath $BuildTemp -PathType Container) {
        Remove-Item -LiteralPath $BuildTemp -Recurse -Force -ErrorAction Stop
    }
}
catch {
    Write-Host "Warning: build temp could not be removed: $BuildTemp :: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Apply summary ==="
Write-Host "planned targets = $plannedCount"
Write-Host "preflight failures = 0"
Write-Host "canonical videos ready = $videosReady"
Write-Host "canonical NFOs ready = $nfosReady"
Write-Host "videos created = $videosCreated"
Write-Host "videos reused = $videosReused"
Write-Host "NFOs created = $nfosCreated"
Write-Host "NFOs reused = $nfosReused"
Write-Host "source media modified = 0"
Write-Host "source media moved = 0"
Write-Host "unmanaged target overwritten = 0"
Write-Host "manifest ready = true"
Write-Host "build log ready = true"
Write-Host "Manifest: $ManifestPath"
Write-Host "Build log: $BuildLogPath"