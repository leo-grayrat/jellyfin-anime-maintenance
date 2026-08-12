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

$commonPath = Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Expected helper library does not exist yet: $commonPath"
}
. $commonPath

Assert-Equal (Get-CvEpisodeKey -Season 1 -Episode 2) "S01E02" "episode key"

$relative = Get-CvRelativeDirectory `
    -SourceDirectory 'D:\Bangumi\2026\2026-07\Work A' `
    -LibraryRoot 'D:\Bangumi\2026\2026-07'
Assert-Equal $relative 'Work A' "relative directory"

$longDrivePath = 'D:\' + (('very-long-folder\' * 20)) + 'episode.mkv'
Assert-True ($longDrivePath.Length -gt 260) "long-path fixture exceeds MAX_PATH"
Assert-Equal (Get-CvVolumeRoot -Path $longDrivePath) 'D:\' "volume root from long drive path"
Assert-Equal (Get-CvVolumeRoot -Path '\\?\D:\very-long-folder\episode.mkv') 'D:\' "volume root from extended drive path"
Assert-Equal (Get-CvVolumeRoot -Path '\\server\share\folder\episode.mkv') '\\server\share\' "volume root from UNC path"
Assert-Equal (Get-CvVolumeRoot -Path '\\?\UNC\server\share\folder\episode.mkv') '\\server\share\' "volume root from extended UNC path"

$virtualFolderCollection = New-Object System.Collections.ArrayList
[void]$virtualFolderCollection.Add([pscustomobject]@{
    Name = 'Library A'
    Locations = @('D:\Media\A')
})
[void]$virtualFolderCollection.Add([pscustomobject]@{
    Name = 'Library B'
    Locations = @('D:\Media\B1', 'D:\Media\B2')
})
$libraryLocations = @(Get-CvLibraryLocations -VirtualFolders $virtualFolderCollection)
Assert-Equal $libraryLocations.Count 3 "virtual folder collection expands to individual locations"
Assert-Equal $libraryLocations[0].LibraryName 'Library A' "first library name remains individual"
Assert-Equal $libraryLocations[0].Root 'D:\Media\A' "first library root"
Assert-Equal $libraryLocations[1].LibraryName 'Library B' "second library name remains individual"
Assert-Equal $libraryLocations[1].Root 'D:\Media\B1' "second library first root"
Assert-Equal $libraryLocations[2].LibraryName 'Library B' "second library name repeats for second root"
Assert-Equal $libraryLocations[2].Root 'D:\Media\B2' "second library second root"

$paths = Get-CvCanonicalPaths `
    -ViewRoot 'D:\Resource\BangumiLink\View' `
    -LibraryName '2026-07' `
    -RelativeDirectory 'Work A' `
    -VideoPath 'D:\Bangumi\2026\2026-07\Work A\[Group] Show [02].mkv' `
    -NfoPath 'D:\Bangumi\2026\2026-07\Work A\[Group] Show [02].nfo' `
    -ExpectedKey 'S01E02'
Assert-Equal $paths.Video 'D:\Resource\BangumiLink\View\2026-07\Work A\S01E02 - [Group] Show [02].mkv' "canonical video path"
Assert-Equal $paths.Nfo 'D:\Resource\BangumiLink\View\2026-07\Work A\S01E02 - [Group] Show [02].nfo' "canonical nfo path"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("canonical-view-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $video = Join-Path $tempRoot "episode01.mkv"
    $nfo = Join-Path $tempRoot "episode01.nfo"
    [System.IO.File]::WriteAllText($video, "video")
    [System.IO.File]::WriteAllText($nfo, "<episodedetails><season>1</season><episode>2</episode></episodedetails>")

    $csvOk = Join-Path $tempRoot "targets-ok.csv"
    @(
        [pscustomobject]@{ Work = "A"; RuleId = "r1"; Action = "WRITE"; VideoPath = $video; Season = "1"; Episode = "2" },
        [pscustomobject]@{ Work = "A"; RuleId = "r2"; Action = "WRITE"; VideoPath = $video; Season = "1"; Episode = "2" }
    ) | Export-Csv -LiteralPath $csvOk -NoTypeInformation -Encoding UTF8

    $targets = @(Get-CvCorrectionTargets -CsvPath $csvOk -ExpectedCount 1)
    Assert-Equal $targets.Count 1 "identical duplicate targets collapse"
    Assert-Equal $targets[0].ExpectedKey "S01E02" "target expected key"

    $csvConflict = Join-Path $tempRoot "targets-conflict.csv"
    @(
        [pscustomobject]@{ Work = "A"; RuleId = "r1"; Action = "WRITE"; VideoPath = $video; Season = "1"; Episode = "2" },
        [pscustomobject]@{ Work = "A"; RuleId = "r2"; Action = "WRITE"; VideoPath = $video; Season = "1"; Episode = "3" }
    ) | Export-Csv -LiteralPath $csvConflict -NoTypeInformation -Encoding UTF8
    Assert-Throws { Get-CvCorrectionTargets -CsvPath $csvConflict -ExpectedCount 1 | Out-Null } "conflicting duplicate targets"

    $identity = Get-CvNfoIdentity -NfoPath $nfo
    Assert-Equal $identity.Season 1 "nfo season"
    Assert-Equal $identity.Episode 2 "nfo episode"

    $badNfo = Join-Path $tempRoot "bad.nfo"
    [System.IO.File]::WriteAllText($badNfo, "<episodedetails><season>1</season></episodedetails>")
    Assert-Throws { Get-CvNfoIdentity -NfoPath $badNfo | Out-Null } "missing episode node"

    $targetPath = Join-Path $tempRoot "managed.mkv"
    [System.IO.File]::WriteAllText($targetPath, "video")
    $manifestRows = @(
        [pscustomobject]@{
            Work = "old"
            OriginalVideo = $video
            OriginalNfo = $nfo
            CanonicalVideo = $targetPath
            CanonicalNfo = (Join-Path $tempRoot "managed.nfo")
        }
    )
    $manifestIndex = Get-CvManifestIndex -Rows $manifestRows
    $owned = Test-CvExistingTarget -TargetPath $targetPath -SourcePath $video -ManifestIndex $manifestIndex -ManifestSourceColumn "OriginalVideo"
    Assert-Equal $owned.State "REUSABLE" "manifest-owned same-source target"

    $unmanagedPath = Join-Path $tempRoot "unmanaged.mkv"
    [System.IO.File]::WriteAllText($unmanagedPath, "video")
    $unmanaged = Test-CvExistingTarget -TargetPath $unmanagedPath -SourcePath $video -ManifestIndex $manifestIndex -ManifestSourceColumn "OriginalVideo"
    Assert-Equal $unmanaged.State "CONFLICT" "unmanaged existing target"

    $replacementRow = [pscustomobject]@{
        Work = "new"
        OriginalVideo = $video
        OriginalNfo = $nfo
        CanonicalVideo = $targetPath
        CanonicalNfo = (Join-Path $tempRoot "managed.nfo")
    }
    $otherRow = [pscustomobject]@{
        Work = "other"
        OriginalVideo = (Join-Path $tempRoot "other.mkv")
        OriginalNfo = (Join-Path $tempRoot "other.nfo")
        CanonicalVideo = (Join-Path $tempRoot "other-canonical.mkv")
        CanonicalNfo = (Join-Path $tempRoot "other-canonical.nfo")
    }
    $merged = @(Merge-CvManifestRows -ExistingRows @($manifestRows[0], $otherRow) -NewRows @($replacementRow))
    Assert-Equal $merged.Count 2 "manifest merge does not duplicate canonical video"
    $mergedReplacement = @($merged | Where-Object { (Get-CvPathKey -Path $_.CanonicalVideo) -eq (Get-CvPathKey -Path $targetPath) })
    Assert-Equal $mergedReplacement.Count 1 "manifest replacement is unique"
    Assert-Equal $mergedReplacement[0].Work "new" "manifest merge replaces existing row"

    $buildRows = @(
        [pscustomobject]@{ CanonicalVideo = 'D:\View\created-video.mkv'; CanonicalNfo = 'D:\View\created-video.nfo'; VideoResult = 'CREATED'; NfoResult = 'CREATED' },
        [pscustomobject]@{ CanonicalVideo = 'D:\View\reused-video.mkv'; CanonicalNfo = 'D:\View\reused-video.nfo'; VideoResult = 'REUSED'; NfoResult = 'REUSED' },
        [pscustomobject]@{ CanonicalVideo = 'D:\View\mixed-video.mkv'; CanonicalNfo = 'D:\View\mixed-video.nfo'; VideoResult = 'CREATED'; NfoResult = 'REUSED' }
    )
    $rollbackPaths = @(Get-CvRollbackPaths -BuildRows $buildRows)
    Assert-Equal $rollbackPaths.Count 3 "rollback contains only current-build-created files"
    Assert-True ($rollbackPaths -contains 'D:\View\created-video.mkv') "rollback includes created video"
    Assert-True ($rollbackPaths -contains 'D:\View\created-video.nfo') "rollback includes created nfo"
    Assert-True ($rollbackPaths -contains 'D:\View\mixed-video.mkv') "rollback includes mixed created video"
    Assert-True (-not ($rollbackPaths -contains 'D:\View\reused-video.mkv')) "rollback excludes reused video"
    Assert-True (-not ($rollbackPaths -contains 'D:\View\reused-video.nfo')) "rollback excludes reused nfo"

    $nativeDir = Join-Path $tempRoot "native[02]"
    New-CvNativeDirectory -Path $nativeDir
    Assert-True (Test-Path -LiteralPath $nativeDir -PathType Container) "native directory creation"

    $nativeSource = Join-Path $tempRoot "source[02].bin"
    [System.IO.File]::WriteAllText($nativeSource, "hardlink-data")
    $nativeLink = Join-Path $nativeDir "link[02].bin"
    New-CvNativeHardLink -Path $nativeLink -Target $nativeSource | Out-Null
    Assert-True (Test-Path -LiteralPath $nativeLink -PathType Leaf) "native hardlink creation"
    Assert-Equal (Get-CvNativeFileLength -Path $nativeLink) (Get-CvNativeFileLength -Path $nativeSource) "native hardlink length"

    $nativeCopy = Join-Path $nativeDir "copy[02].nfo"
    Copy-CvNativeFile -Source $nfo -Destination $nativeCopy -Overwrite
    Assert-True (Test-Path -LiteralPath $nativeCopy -PathType Leaf) "native file copy"
    Assert-Equal (Get-CvNativeFileLength -Path $nativeCopy) ([long](Get-Item -LiteralPath $nfo).Length) "native copied file length"

    Remove-CvNativeFile -Path $nativeLink
    Remove-CvNativeFile -Path $nativeCopy
    Assert-True (-not (Test-Path -LiteralPath $nativeLink)) "native hardlink removal"
    Assert-True (-not (Test-Path -LiteralPath $nativeCopy)) "native copy removal"
    Assert-True (Remove-CvNativeDirectoryIfEmpty -Path $nativeDir) "native empty directory removal"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$commandPath = Join-Path $PSScriptRoot "..\scripts\build_jellyfin_canonical_view.ps1"
if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
    throw "Expected command script does not exist yet: $commandPath"
}

$commandSource = [System.IO.File]::ReadAllText($commandPath)
foreach ($requiredText in @(
    '[string]$Root = "D:\Resource\BangumiLink"',
    '[switch]$Apply',
    '$ExpectedTargetCount = 243',
    '/Library/VirtualFolders'
)) {
    Assert-True ($commandSource.Contains($requiredText)) "command source contains $requiredText"
}
Assert-True (-not $commandSource.Contains('_jellyfin_repair_staging')) "command does not use root-level legacy staging"
Assert-True (-not $commandSource.Contains('New-Item -ItemType HardLink')) "command does not use PowerShell hardlink provider"
Assert-True (-not $commandSource.Contains('[System.IO.Path]::GetPathRoot')) "command avoids MAX_PATH-sensitive GetPathRoot"
Assert-True (-not $commandSource.Contains('Resolve-CvSourceVideo')) "command does not guess renamed source paths"
Assert-True (-not $commandSource.Contains('Source aliases:')) "command does not carry pilot source-alias reporting"
Assert-True ($commandSource.Contains('New-CvNativeHardLink')) "apply uses native hardlink helper"
Assert-True ($commandSource.Contains('Merge-CvManifestRows')) "apply merges manifest deterministically"
Assert-True ($commandSource.Contains('build-')) "apply uses build-scoped temp/log naming"
Assert-True ($commandSource.Contains('Rollback')) "apply contains rollback path"

$commonSource = [System.IO.File]::ReadAllText($commonPath)
Assert-True (-not $commonSource.Contains('[System.IO.Path]::GetPathRoot')) "helper avoids MAX_PATH-sensitive GetPathRoot"
Assert-True (-not $commonSource.Contains('Resolve-CvSourceVideo')) "helper does not guess renamed source paths"

Write-Host "PASS: canonical view helper, native filesystem, and command safety tests"