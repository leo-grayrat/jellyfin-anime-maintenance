$ErrorActionPreference = "Stop"

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "ASSERT EQUAL FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

. (Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_common.ps1")

$tempRoot = Join-Path $env:TEMP ("fcv-copy-reuse-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $source = Join-Path $tempRoot "source.nfo"
    $copyTarget = Join-Path $tempRoot "copy.nfo"
    $hardTarget = Join-Path $tempRoot "hard.mkv"
    [System.IO.File]::WriteAllText($source, "abc")
    [System.IO.File]::WriteAllText($copyTarget, "jellyfin-expanded-copy")
    [System.IO.File]::WriteAllText($hardTarget, "wrong-length")

    $copyRows = @(
        [pscustomobject]@{
            SourcePath = $source
            CanonicalPath = $copyTarget
            Operation = "COPY"
        }
    )
    $copyState = Test-FcvExistingTarget `
        -TargetPath $copyTarget `
        -SourcePath $source `
        -ExpectedLength ([long](Get-Item -LiteralPath $source).Length) `
        -ManifestIndex (Get-FcvManifestIndex -Rows $copyRows)
    Assert-Equal $copyState.State "REUSABLE" "managed copy may diverge from source after Jellyfin edits"

    $hardRows = @(
        [pscustomobject]@{
            SourcePath = $source
            CanonicalPath = $hardTarget
            Operation = "HARDLINK"
        }
    )
    $hardState = Test-FcvExistingTarget `
        -TargetPath $hardTarget `
        -SourcePath $source `
        -ExpectedLength ([long](Get-Item -LiteralPath $source).Length) `
        -ManifestIndex (Get-FcvManifestIndex -Rows $hardRows)
    Assert-Equal $hardState.State "CONFLICT" "managed hardlink must still match source length"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "PASS: managed copy reuse preserves Phase 1 NFO semantics"
