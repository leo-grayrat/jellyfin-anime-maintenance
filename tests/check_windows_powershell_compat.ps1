$ErrorActionPreference = "Stop"

$scriptPaths = @(
    (Join-Path $PSScriptRoot "..\scripts\jellyfin_tv_nfo_fix.ps1"),
    (Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1"),
    (Join-Path $PSScriptRoot "..\scripts\build_jellyfin_canonical_view.ps1")
)

foreach ($scriptPath in $scriptPaths) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Script not found: $scriptPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($scriptPath)
    if ($bytes | Where-Object { $_ -gt 127 }) {
        throw "$scriptPath contains non-ASCII bytes. Windows PowerShell 5.1 may misread UTF-8 without BOM."
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $messages = ($errors | ForEach-Object { $_.Message }) -join "; "
        throw ("PowerShell parser errors in {0}: {1}" -f $scriptPath, $messages)
    }
}

Write-Host "PASS: PowerShell scripts are ASCII-only and parse successfully."
