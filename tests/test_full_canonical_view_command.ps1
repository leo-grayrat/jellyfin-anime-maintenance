$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE FAILED: $Message" }
}

$commandPath = Join-Path $PSScriptRoot "..\scripts\build_jellyfin_full_canonical_view.ps1"
if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
    throw "Expected full canonical view command does not exist yet: $commandPath"
}

$source = [System.IO.File]::ReadAllText($commandPath)
foreach ($required in @(
    '[string]$ProductionRoot = "D:\Bangumi"',
    '[int]$ExpectedVideoCount = 676',
    '[int]$ExpectedTargetCount = 243',
    '[string]$Root = "D:\Resource\BangumiLink"',
    'canonical_view_common.ps1',
    'tv_audit_common.ps1',
    'full_canonical_view_common.ps1',
    '/System/Info',
    '/Library/VirtualFolders',
    'full-manifest-v2.csv',
    'full-build-',
    'New-FcvPlan',
    'Test-FcvExistingTarget',
    'New-CvNativeHardLink',
    'Copy-CvNativeFile',
    'Move-CvNativeFileReplace',
    'Rollback'
)) {
    Assert-True ($source.Contains($required)) "command source contains $required"
}

foreach ($forbidden in @(
    '-Method Post',
    '-Method Put',
    '-Method Patch',
    '-Method Delete',
    '/Refresh',
    'New-Item -ItemType HardLink',
    'UPDATE sqlite',
    'DELETE FROM',
    'INSERT INTO',
    'ALTER TABLE',
    'Move-Item -LiteralPath $row.SourcePath',
    'Remove-Item -LiteralPath $row.SourcePath'
)) {
    Assert-True ($source.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "command excludes mutating token $forbidden"
}

Assert-True ($source.IndexOf('-Method Get', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Jellyfin requests use GET"
Assert-True ($source.IndexOf('CollectionType', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command filters TV libraries"
Assert-True ($source.IndexOf('manifest.csv', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command reads Phase 1 manifest proof"
Assert-True ($source.IndexOf('full-manifest-v2.csv', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command uses separate Phase 2 manifest"

$dryRunIndex = $source.IndexOf('if (-not $Apply)', [System.StringComparison]::OrdinalIgnoreCase)
$firstWriteIndex = $source.IndexOf('New-CvNativeDirectoryTree -Path $Root', [System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($dryRunIndex -ge 0) "command has dry-run gate"
Assert-True ($firstWriteIndex -gt $dryRunIndex) "filesystem creation starts only after dry-run exit"

$manifestTempIndex = $source.IndexOf('$ManifestTempPath', [System.StringComparison]::OrdinalIgnoreCase)
$manifestMoveIndex = $source.IndexOf('Move-CvNativeFileReplace -Source $ManifestTempPath -Destination $FullManifestPath', [System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($manifestTempIndex -ge 0) "command stages manifest temp"
Assert-True ($manifestMoveIndex -gt $manifestTempIndex) "manifest replacement happens after temp creation"
Assert-True ($source.IndexOf('Remove-CvNativeFile -Path $FullManifestPath', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "old manifest is never deleted before replace"

Assert-True ($source.IndexOf('Set-Cv', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "command does not contain hidden source mutation helper"
Assert-True ($source.IndexOf('/Library/VirtualFolders?', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "command does not mutate library roots"

Write-Host "PASS: full canonical view command safety contract"
