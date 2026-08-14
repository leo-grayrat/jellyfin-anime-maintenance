$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE FAILED: $Message" }
}

$commandPath = Join-Path $PSScriptRoot "..\scripts\build_jellyfin_full_canonical_view.ps1"
$commonPath = Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_common.ps1"
$applyPath = Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_apply.ps1"
foreach ($path in @($commandPath, $commonPath, $applyPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected full canonical view implementation file does not exist: $path"
    }
}

$source = [System.IO.File]::ReadAllText($commandPath)
$commonSource = [System.IO.File]::ReadAllText($commonPath)
$applySource = [System.IO.File]::ReadAllText($applyPath)
$combined = $source + "`n" + $commonSource + "`n" + $applySource

foreach ($required in @(
    '[string]$ProductionRoot = "D:\Bangumi"',
    '[int]$ExpectedVideoCount = 676',
    '[int]$ExpectedTargetCount = 243',
    '[string]$Root = "D:\Resource\BangumiLink"',
    'canonical_view_common.ps1',
    'tv_audit_common.ps1',
    'full_canonical_view_common.ps1',
    'full_canonical_view_apply.ps1',
    '/System/Info',
    '/Library/VirtualFolders',
    'full-manifest-v2.csv',
    'New-FcvPlan',
    'Test-FcvExistingTarget',
    'Invoke-FcvApplyBuild'
)) {
    Assert-True ($source.Contains($required)) "command source contains $required"
}

foreach ($required in @(
    'full-build-',
    'New-FcvNativeHardLink',
    'Copy-FcvNativeFile',
    'Move-FcvNativeFileReplace',
    'Rollback',
    'Get-FcvRollbackPaths',
    'New-FcvNativeDirectoryTree -Path $Root'
)) {
    Assert-True ($applySource.Contains($required)) "apply source contains $required"
}

foreach ($required in @(
    'Get-FcvNativePathText',
    'Get-FcvDirectoryPath',
    '[CvNativeFileSystem]::CreateHardLink',
    '[CvNativeFileSystem]::CopyFile',
    '[CvNativeFileSystem]::MoveReplace'
)) {
    Assert-True ($commonSource.Contains($required)) "full helper contains native-safe wrapper $required"
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
    Assert-True ($combined.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "implementation excludes unsafe token $forbidden"
}

Assert-True ($source.IndexOf('-Method Get', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Jellyfin requests use GET"
Assert-True ($source.IndexOf('CollectionType', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command filters TV libraries"
Assert-True ($source.IndexOf('manifest.csv', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command reads Phase 1 manifest proof"
Assert-True ($source.IndexOf('full-manifest-v2.csv', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "command uses separate Phase 2 manifest"

$dryRunIndex = $source.IndexOf('if (-not $Apply)', [System.StringComparison]::OrdinalIgnoreCase)
$applyIndex = $source.IndexOf('Invoke-FcvApplyBuild', [System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($dryRunIndex -ge 0) "command has dry-run gate"
Assert-True ($applyIndex -gt $dryRunIndex) "Apply transaction is called only after dry-run exit"
Assert-True ($source.IndexOf('New-FcvNativeDirectoryTree -Path $Root', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "command preflight layer does not create filesystem directories"

$manifestTempIndex = $applySource.IndexOf('$ManifestTempPath', [System.StringComparison]::OrdinalIgnoreCase)
$manifestMoveIndex = $applySource.IndexOf('Move-FcvNativeFileReplace -Source $ManifestTempPath -Destination $FullManifestPath', [System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($manifestTempIndex -ge 0) "apply stages manifest temp"
Assert-True ($manifestMoveIndex -gt $manifestTempIndex) "manifest replacement happens after temp creation"
Assert-True ($applySource.IndexOf('Remove-FcvNativeFile -Path $FullManifestPath', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "old manifest is never deleted before replace"

$rollbackCheckIndex = $applySource.IndexOf('Test-FcvPathUnderOrEqual -Path $path -Root $ViewRoot', [System.StringComparison]::OrdinalIgnoreCase)
$rollbackRemoveIndex = $applySource.IndexOf('Remove-FcvNativeFile -Path $path', [System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($rollbackCheckIndex -ge 0) "rollback verifies destination stays under View"
Assert-True ($rollbackRemoveIndex -gt $rollbackCheckIndex) "rollback validates path before file removal"

Assert-True ($applySource.IndexOf('[System.IO.Path]::GetFullPath', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "apply avoids MAX_PATH-sensitive GetFullPath"
Assert-True ($applySource.IndexOf('[System.IO.Path]::GetDirectoryName', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "apply avoids MAX_PATH-sensitive GetDirectoryName"
Assert-True ($commonSource.IndexOf('[System.IO.Path]::GetFullPath', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "full helper avoids MAX_PATH-sensitive GetFullPath"
Assert-True ($commonSource.IndexOf('[System.IO.Path]::GetDirectoryName', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "full helper avoids MAX_PATH-sensitive GetDirectoryName"

Assert-True ($combined.IndexOf('Set-Cv', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "implementation does not contain hidden source mutation helper"
Assert-True ($source.IndexOf('/Library/VirtualFolders?', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "command does not mutate library roots"

Write-Host "PASS: full canonical view command and apply safety contract"
