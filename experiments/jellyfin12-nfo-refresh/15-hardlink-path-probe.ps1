# HARDLINK PATH PROBE
#
# Read/write scope: creates only tiny temporary files under StagingRoot and
# deletes them before exit. It does not call Jellyfin and does not touch media.
#
# Purpose:
# 1. Verify whether Windows PowerShell New-Item -ItemType HardLink can use a
#    target path containing square brackets such as [02].
# 2. Compare that behavior with the native Windows CreateHardLinkW API.

[CmdletBinding()]
param(
    [string]$StagingRoot = "D:\_jellyfin_repair_staging"
)

$ErrorActionPreference = "Stop"

$StagingRoot = [System.IO.Path]::GetFullPath($StagingRoot)
$probeRoot = [System.IO.Path]::Combine(
    $StagingRoot,
    "hardlink-path-probe-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
)

$source = [System.IO.Path]::Combine($probeRoot, "source[02].tmp")
$newItemLink = [System.IO.Path]::Combine($probeRoot, "newitem-link[02].tmp")
$nativeLink = [System.IO.Path]::Combine($probeRoot, "native-link[02].tmp")

if (-not ("NativeHardLink" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class NativeHardLink
{
    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(
        string lpFileName,
        string lpExistingFileName,
        IntPtr lpSecurityAttributes);

    public static void Create(string newPath, string existingPath)
    {
        if (!CreateHardLinkW(newPath, existingPath, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

Write-Host ""
Write-Host "=== Hardlink Path Probe ==="
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "Probe root:         $probeRoot"
Write-Host "Source:             $source"
Write-Host ""

$newItemResult = "NOT_RUN"
$newItemError = ""
$nativeResult = "NOT_RUN"
$nativeError = ""

try {
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($source, "hardlink-path-probe")

    Write-Host "Source exists (LiteralPath): $(Test-Path -LiteralPath $source)"
    Write-Host "Source exists (Path):        $(Test-Path -Path $source)"
    Write-Host ""

    Write-Host "--- Test 1: New-Item -ItemType HardLink ---"
    try {
        New-Item -ItemType HardLink -Path $newItemLink -Target $source -ErrorAction Stop | Out-Null

        if (-not (Test-Path -LiteralPath $newItemLink -PathType Leaf)) {
            throw "New-Item returned without error, but the link path does not exist."
        }

        $newItemResult = "SUCCEEDED"
        Write-Host "NEW-ITEM RESULT: SUCCEEDED" -ForegroundColor Green
    }
    catch {
        $newItemResult = "FAILED"
        $newItemError = $_.Exception.Message
        Write-Host "NEW-ITEM RESULT: FAILED" -ForegroundColor Yellow
        Write-Host "NEW-ITEM ERROR:  $newItemError"
    }

    Write-Host ""
    Write-Host "--- Test 2: native CreateHardLinkW ---"
    try {
        [NativeHardLink]::Create($nativeLink, $source)

        if (-not (Test-Path -LiteralPath $nativeLink -PathType Leaf)) {
            throw "CreateHardLinkW returned success, but the link path does not exist."
        }

        $nativeResult = "SUCCEEDED"
        Write-Host "NATIVE RESULT: SUCCEEDED" -ForegroundColor Green
    }
    catch {
        $nativeResult = "FAILED"
        $nativeError = $_.Exception.Message
        Write-Host "NATIVE RESULT: FAILED" -ForegroundColor Red
        Write-Host "NATIVE ERROR:  $nativeError"
    }

    Write-Host ""
    Write-Host "=== Summary ==="
    Write-Host "New-Item hardlink: $newItemResult"
    Write-Host "Native hardlink:   $nativeResult"

    if ($newItemResult -eq "FAILED" -and $nativeResult -eq "SUCCEEDED") {
        Write-Host "CLASSIFICATION: POWERSHELL PROVIDER PATH HANDLING" -ForegroundColor Green
        Write-Host "The native Windows hardlink API works with the same [02] source path."
    }
    elseif ($newItemResult -eq "SUCCEEDED" -and $nativeResult -eq "SUCCEEDED") {
        Write-Host "CLASSIFICATION: BOTH METHODS WORK IN THIS ISOLATED PROBE" -ForegroundColor Yellow
        Write-Host "The media-path failure needs a different explanation."
    }
    elseif ($nativeResult -eq "FAILED") {
        Write-Host "CLASSIFICATION: NATIVE HARDLINK ALSO FAILED" -ForegroundColor Red
        Write-Host "Do not retry the Jellyfin hardlink pilot until this native failure is understood."
    }
}
finally {
    foreach ($path in @($newItemLink, $nativeLink, $source)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $probeRoot -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $probeRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $probeRoot -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "Cleanup complete. No media files or Jellyfin data were touched."
}
