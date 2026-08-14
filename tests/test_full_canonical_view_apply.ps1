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

. (Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_apply.ps1")

$temp = Join-Path $env:TEMP ("fcv-apply-test-" + [guid]::NewGuid().ToString("N"))
$sourceRoot = Join-Path $temp "source"
$root = Join-Path $temp "work"
$viewRoot = Join-Path $root "View"
$tempRoot = Join-Path $root "Temp"
$logsRoot = Join-Path $root "Logs"
$manifestPath = Join-Path $logsRoot "full-manifest-v2.csv"
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

try {
    $videoSource = Join-Path $sourceRoot "ep01.mkv"
    $nfoSource = Join-Path $sourceRoot "ep01.nfo"
    [System.IO.File]::WriteAllBytes($videoSource, [byte[]](1, 2, 3, 4, 5))
    [System.IO.File]::WriteAllText($nfoSource, "<episodedetails><season>1</season><episode>1</episode></episodedetails>")

    $videoTarget = Join-Path (Join-Path $viewRoot "TV") "S01E01 - ep01.mkv"
    $nfoTarget = Join-Path (Join-Path $viewRoot "TV") "S01E01 - ep01.nfo"
    $plan = @(
        [pscustomobject]@{
            SourcePath = $videoSource
            CanonicalPath = $videoTarget
            LibraryName = "TV"
            LibraryRoot = $sourceRoot
            RelativePath = "ep01.mkv"
            Role = "CORRECTION_VIDEO"
            Operation = "HARDLINK"
            SourceLength = 5L
            ExpectedKey = "S01E01"
            State = "MISSING"
        },
        [pscustomobject]@{
            SourcePath = $nfoSource
            CanonicalPath = $nfoTarget
            LibraryName = "TV"
            LibraryRoot = $sourceRoot
            RelativePath = "ep01.nfo"
            Role = "CORRECTION_SIDECAR"
            Operation = "COPY"
            SourceLength = [long](Get-Item -LiteralPath $nfoSource).Length
            ExpectedKey = "S01E01"
            State = "MISSING"
        }
    )
    $preflight = [pscustomobject]@{ Plan = $plan; FullManifestRows = @() }

    $first = Invoke-FcvApplyBuild -Preflight $preflight -Root $root -ViewRoot $viewRoot -TempRoot $tempRoot -LogsRoot $logsRoot -FullManifestPath $manifestPath
    Assert-Equal $first.CreatedCount 2 "first apply creates both rows"
    Assert-Equal $first.ReusedCount 0 "first apply reuses nothing"
    Assert-True (Test-CvNativeFile -Path $videoTarget) "hardlink target exists"
    Assert-True (Test-CvNativeFile -Path $nfoTarget) "copy target exists"
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) "full manifest exists"
    Assert-True (Test-Path -LiteralPath $first.BuildLogPath -PathType Leaf) "build log exists"
    Assert-True (Test-Path -LiteralPath $videoSource -PathType Leaf) "video source remains"
    Assert-True (Test-Path -LiteralPath $nfoSource -PathType Leaf) "nfo source remains"

    $manifestRows = @(Import-Csv -LiteralPath $manifestPath)
    Assert-Equal $manifestRows.Count 2 "manifest has one row per plan file"
    $manifestIndex = Get-FcvManifestIndex -Rows $manifestRows
    foreach ($row in $plan) {
        $state = Test-FcvExistingTarget -TargetPath $row.CanonicalPath -SourcePath $row.SourcePath -ExpectedLength $row.SourceLength -ManifestIndex $manifestIndex
        Assert-Equal $state.State "REUSABLE" "created file is reusable from manifest"
        $row.State = "REUSABLE"
    }

    $secondPreflight = [pscustomobject]@{ Plan = $plan; FullManifestRows = $manifestRows }
    $second = Invoke-FcvApplyBuild -Preflight $secondPreflight -Root $root -ViewRoot $viewRoot -TempRoot $tempRoot -LogsRoot $logsRoot -FullManifestPath $manifestPath
    Assert-Equal $second.CreatedCount 0 "second apply creates nothing"
    Assert-Equal $second.ReusedCount 2 "second apply reuses all rows"

    $rollbackRoot = Join-Path $temp "rollback-work"
    $rollbackView = Join-Path $rollbackRoot "View"
    $rollbackTemp = Join-Path $rollbackRoot "Temp"
    $rollbackLogs = Join-Path $rollbackRoot "Logs"
    $rollbackManifest = Join-Path $rollbackLogs "full-manifest-v2.csv"
    $rollbackGoodTarget = Join-Path (Join-Path $rollbackView "TV") "good.mkv"
    $rollbackBadTarget = Join-Path (Join-Path $rollbackView "TV") "bad.nfo"
    $rollbackPlan = @(
        [pscustomobject]@{
            SourcePath = $videoSource; CanonicalPath = $rollbackGoodTarget; LibraryName = "TV"; LibraryRoot = $sourceRoot; RelativePath = "ep01.mkv"; Role = "PASSTHROUGH_VIDEO"; Operation = "HARDLINK"; SourceLength = 5L; ExpectedKey = ""; State = "MISSING"
        },
        [pscustomobject]@{
            SourcePath = $nfoSource; CanonicalPath = $rollbackBadTarget; LibraryName = "TV"; LibraryRoot = $sourceRoot; RelativePath = "ep01.nfo"; Role = "PASSTHROUGH_FILE"; Operation = "INVALID"; SourceLength = [long](Get-Item -LiteralPath $nfoSource).Length; ExpectedKey = ""; State = "MISSING"
        }
    )
    $rollbackPreflight = [pscustomobject]@{ Plan = $rollbackPlan; FullManifestRows = @() }
    Assert-Throws {
        Invoke-FcvApplyBuild -Preflight $rollbackPreflight -Root $rollbackRoot -ViewRoot $rollbackView -TempRoot $rollbackTemp -LogsRoot $rollbackLogs -FullManifestPath $rollbackManifest | Out-Null
    } "invalid second row triggers rollback"
    Assert-True (-not (Test-CvNativeFile -Path $rollbackGoodTarget)) "rollback removes first created destination"
    Assert-True (Test-Path -LiteralPath $videoSource -PathType Leaf) "rollback keeps source video"
    Assert-True (Test-Path -LiteralPath $nfoSource -PathType Leaf) "rollback keeps source nfo"
    Assert-True (-not (Test-Path -LiteralPath $rollbackManifest -PathType Leaf)) "failed build does not commit manifest"
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "PASS: full canonical view apply, idempotency, and rollback fixtures"
