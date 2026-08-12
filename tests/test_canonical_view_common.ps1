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

$commonSource = [System.IO.File]::ReadAllText($commonPath)
Assert-True (-not $commonSource.Contains('[System.IO.Path]::GetPathRoot')) "helper avoids MAX_PATH-sensitive GetPathRoot"

Write-Host "PASS: canonical view helper and command safety tests"
