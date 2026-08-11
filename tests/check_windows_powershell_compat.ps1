$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\scripts\jellyfin_tv_nfo_fix.ps1"
$bytes = [System.IO.File]::ReadAllBytes($scriptPath)

if ($bytes | Where-Object { $_ -gt 127 }) {
    throw "jellyfin_tv_nfo_fix.ps1 contains non-ASCII bytes. Windows PowerShell 5.1 may misread UTF-8 without BOM."
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

if ($errors.Count -gt 0) {
    $messages = ($errors | ForEach-Object { $_.Message }) -join "; "
    throw "PowerShell parser errors: $messages"
}

Write-Host "PASS: PowerShell script source is ASCII-only and parses successfully."
