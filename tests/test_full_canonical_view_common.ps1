$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE FAILED: $Message" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "ASSERT EQUAL FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "ASSERT THROWS FAILED: $Message" }
}

$canonicalPath = Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1"
$auditPath = Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1"
$fullPath = Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_common.ps1"

foreach ($required in @($canonicalPath, $auditPath, $fullPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Expected helper does not exist yet: $required"
    }
}

. $canonicalPath
. $auditPath
. $fullPath

Assert-Equal (Get-FcvFileStem -Path 'D:\TV\Show\ep01.mkv') 'ep01' "video stem"
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.mkv' -IsVideo $true) 'HARDLINK' "video hardlink"
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.ass' -IsVideo $false) 'HARDLINK' "subtitle hardlink"
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.nfo' -IsVideo $false) 'COPY' "nfo copy"
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\poster.jpg' -IsVideo $false) 'COPY' "unknown metadata copy"
Assert-True (Test-FcvVideoPath -Path 'D:\TV\Show\ep01.MKV') "video extension is case insensitive"
Assert-True (-not (Test-FcvVideoPath -Path 'D:\TV\Show\ep01.ass')) "subtitle is not video"

Assert-Throws {
    Assert-FcvDisjointRoots -SourceRoots @('D:\TV') -ViewRoot 'D:\TV\View'
} "view inside source root"
Assert-Throws {
    Assert-FcvDisjointRoots -SourceRoots @('D:\Resource\BangumiLink\View\Source') -ViewRoot 'D:\Resource\BangumiLink\View'
} "source inside view root"
Assert-FcvDisjointRoots -SourceRoots @('D:\Bangumi') -ViewRoot 'D:\Resource\BangumiLink\View'

$sourceFiles = @(
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\2026\Show\ep01.mkv'; Length = 100L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\2026\Show\ep01.ass'; Length = 10L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\2026\Show\ep01.nfo'; Length = 20L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\2026\Show\ep02.mkv'; Length = 101L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\2026\Show\poster.jpg'; Length = 30L }
)
$targets = @(
    [pscustomobject]@{
        Work = 'Show'
        VideoPath = 'D:\Bangumi\2026\Show\ep01.mkv'
        TargetSeason = 1
        TargetEpisode = 2
        ExpectedKey = 'S01E02'
    }
)
$viewRoot = 'D:\Resource\BangumiLink\View'
$plan = @(New-FcvPlan -SourceFiles $sourceFiles -Targets $targets -ViewRoot $viewRoot)
Assert-Equal $plan.Count 5 "one plan row per source file"

$correctionVideo = @($plan | Where-Object { $_.Role -eq 'CORRECTION_VIDEO' })
Assert-Equal $correctionVideo.Count 1 "one correction video"
Assert-Equal $correctionVideo[0].CanonicalPath 'D:\Resource\BangumiLink\View\TV\2026\Show\S01E02 - ep01.mkv' "correction video path"
Assert-Equal $correctionVideo[0].Operation 'HARDLINK' "correction video operation"
Assert-Equal $correctionVideo[0].ExpectedKey 'S01E02' "correction video expected key"

$correctionSidecars = @($plan | Where-Object { $_.Role -eq 'CORRECTION_SIDECAR' } | Sort-Object SourcePath)
Assert-Equal $correctionSidecars.Count 2 "two exact-stem correction sidecars"
Assert-Equal $correctionSidecars[0].CanonicalPath 'D:\Resource\BangumiLink\View\TV\2026\Show\S01E02 - ep01.ass' "subtitle renamed with target"
Assert-Equal $correctionSidecars[0].Operation 'HARDLINK' "subtitle sidecar hardlink"
Assert-Equal $correctionSidecars[1].CanonicalPath 'D:\Resource\BangumiLink\View\TV\2026\Show\S01E02 - ep01.nfo' "nfo renamed with target"
Assert-Equal $correctionSidecars[1].Operation 'COPY' "nfo sidecar copy"

$passthroughVideo = @($plan | Where-Object { $_.Role -eq 'PASSTHROUGH_VIDEO' })
Assert-Equal $passthroughVideo.Count 1 "one passthrough video"
Assert-Equal $passthroughVideo[0].CanonicalPath 'D:\Resource\BangumiLink\View\TV\2026\Show\ep02.mkv' "passthrough video keeps name"
Assert-Equal $passthroughVideo[0].ExpectedKey '' "passthrough has no invented episode key"

$passthroughFile = @($plan | Where-Object { $_.Role -eq 'PASSTHROUGH_FILE' })
Assert-Equal $passthroughFile.Count 1 "one unrelated passthrough file"
Assert-Equal $passthroughFile[0].CanonicalPath 'D:\Resource\BangumiLink\View\TV\2026\Show\poster.jpg' "passthrough file keeps name"
Assert-Equal $passthroughFile[0].Operation 'COPY' "unknown passthrough file defaults to copy"

foreach ($ownedSource in @('D:\Bangumi\2026\Show\ep01.mkv', 'D:\Bangumi\2026\Show\ep01.ass', 'D:\Bangumi\2026\Show\ep01.nfo')) {
    Assert-Equal @($plan | Where-Object { (Get-CvPathKey -Path $_.SourcePath) -eq (Get-CvPathKey -Path $ownedSource) }).Count 1 "owned target path appears exactly once"
}

$collisionSources = @(
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi\A'; Path = 'D:\Bangumi\A\same.mkv'; Length = 1L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi\B'; Path = 'D:\Bangumi\B\same.mkv'; Length = 1L }
)
Assert-Throws {
    New-FcvPlan -SourceFiles $collisionSources -Targets @() -ViewRoot $viewRoot | Out-Null
} "canonical collision across roots in one library"

$ambiguousSources = @(
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\Show\same.mkv'; Length = 1L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\Show\same.mp4'; Length = 1L },
    [pscustomobject]@{ LibraryName = 'TV'; LibraryRoot = 'D:\Bangumi'; Path = 'D:\Bangumi\Show\same.nfo'; Length = 1L }
)
$ambiguousTargets = @(
    [pscustomobject]@{ Work = 'A'; VideoPath = 'D:\Bangumi\Show\same.mkv'; TargetSeason = 1; TargetEpisode = 1; ExpectedKey = 'S01E01' },
    [pscustomobject]@{ Work = 'B'; VideoPath = 'D:\Bangumi\Show\same.mp4'; TargetSeason = 1; TargetEpisode = 2; ExpectedKey = 'S01E02' }
)
Assert-Throws {
    New-FcvPlan -SourceFiles $ambiguousSources -Targets $ambiguousTargets -ViewRoot $viewRoot | Out-Null
} "same directory and stem cannot own one sidecar twice"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("full-canonical-view-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $source = Join-Path $tempRoot 'source.bin'
    $target = Join-Path $tempRoot 'target.bin'
    [System.IO.File]::WriteAllText($source, 'abc')
    [System.IO.File]::WriteAllText($target, 'abc')

    $manifestRows = @(
        [pscustomobject]@{
            SourcePath = $source
            CanonicalPath = $target
            LibraryName = 'TV'
            Role = 'PASSTHROUGH_FILE'
            Operation = 'COPY'
            SourceLength = 3L
            ExpectedKey = ''
            BuildId = 'old'
            Status = 'READY'
        }
    )
    $manifestIndex = Get-FcvManifestIndex -Rows $manifestRows
    $managed = Test-FcvExistingTarget -TargetPath $target -SourcePath $source -ExpectedLength 3L -ManifestIndex $manifestIndex
    Assert-Equal $managed.State 'REUSABLE' "manifest-owned target is reusable"

    $unmanaged = Join-Path $tempRoot 'unmanaged.bin'
    [System.IO.File]::WriteAllText($unmanaged, 'abc')
    $conflict = Test-FcvExistingTarget -TargetPath $unmanaged -SourcePath $source -ExpectedLength 3L -ManifestIndex $manifestIndex
    Assert-Equal $conflict.State 'CONFLICT' "unmanaged target is conflict"

    $replacement = [pscustomobject]@{
        SourcePath = $source
        CanonicalPath = $target
        LibraryName = 'TV'
        Role = 'PASSTHROUGH_FILE'
        Operation = 'COPY'
        SourceLength = 3L
        ExpectedKey = ''
        BuildId = 'new'
        Status = 'READY'
    }
    $merged = @(Merge-FcvManifestRows -ExistingRows $manifestRows -NewRows @($replacement))
    Assert-Equal $merged.Count 1 "manifest replacement remains unique"
    Assert-Equal $merged[0].BuildId 'new' "same-source manifest row can be refreshed"

    $differentSource = Join-Path $tempRoot 'other.bin'
    [System.IO.File]::WriteAllText($differentSource, 'abc')
    $badReplacement = $replacement.PSObject.Copy()
    $badReplacement.SourcePath = $differentSource
    Assert-Throws {
        Merge-FcvManifestRows -ExistingRows $manifestRows -NewRows @($badReplacement) | Out-Null
    } "different source cannot take over managed canonical path"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$rollbackRows = @(
    [pscustomobject]@{ SourcePath = 'D:\Source\a.mkv'; CanonicalPath = 'D:\View\a.mkv'; Status = 'CREATED' },
    [pscustomobject]@{ SourcePath = 'D:\Source\b.mkv'; CanonicalPath = 'D:\View\b.mkv'; Status = 'REUSED' },
    [pscustomobject]@{ SourcePath = 'D:\Source\c.nfo'; CanonicalPath = 'D:\View\c.nfo'; Status = 'CREATED' }
)
$rollback = @(Get-FcvRollbackPaths -BuildRows $rollbackRows)
Assert-Equal $rollback.Count 2 "rollback includes only created destinations"
Assert-True ($rollback -contains 'D:\View\a.mkv') "rollback includes created video destination"
Assert-True ($rollback -contains 'D:\View\c.nfo') "rollback includes created sidecar destination"
Assert-True (-not ($rollback -contains 'D:\Source\a.mkv')) "rollback never includes source"
Assert-True (-not ($rollback -contains 'D:\View\b.mkv')) "rollback excludes reused destination"

Write-Host "PASS: full canonical view helper planning and manifest tests"
