# CROSS-SERIES CANONICAL NATIVE-HARDLINK PILOT
#
# Corrected retry of experiment 14.
# Experiment 14 proved its Jellyfin removal/restore logic works, but Windows
# PowerShell 5.1 failed to create a hard link when the -Target path contained
# square brackets such as [02]. Experiment 15 isolated that behavior:
# New-Item -ItemType HardLink fails, while native CreateHardLinkW succeeds.
#
# This wrapper keeps experiment 14 unchanged as historical evidence and only
# replaces New-Item's HardLink behavior with CreateHardLinkW. Directory creation
# is delegated to the real Microsoft.PowerShell.Management\New-Item cmdlet.
# All candidate selection, Jellyfin observation, safety checks, and automatic
# restoration remain those of experiment 14.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",

    [string]$StagingRoot = "",

    [switch]$Apply,

    [int]$PollIntervalSeconds = 2,

    [int]$RemovalTimeoutSeconds = 180,

    [int]$ObservationTimeoutSeconds = 180,

    [int]$RestoreTimeoutSeconds = 180,

    [int]$StableSamples = 5
)

$ErrorActionPreference = "Stop"

if (-not ("CanonicalNativeHardLink" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CanonicalNativeHardLink
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

# Intentionally shadow New-Item only for the child script scope. Experiment 14
# uses New-Item for two operations: Directory and HardLink. Directory creation
# is delegated unchanged; HardLink uses the native Windows API so source paths
# such as "[MingY] ... [02] ... .mkv" are treated literally.
function New-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$Path,

        [string]$ItemType,

        [Alias("Target")]
        [object]$Value,

        [switch]$Force
    )

    if ([string]::Equals($ItemType, "HardLink", [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($null -eq $Path -or $Path.Count -ne 1) {
            throw "Native hardlink wrapper requires exactly one -Path value."
        }

        $existingPath = [string]$Value
        if ([string]::IsNullOrWhiteSpace($existingPath)) {
            throw "Native hardlink wrapper requires one -Target value."
        }

        $newPathFull = [System.IO.Path]::GetFullPath([string]$Path[0])
        $existingPathFull = [System.IO.Path]::GetFullPath($existingPath)

        if (-not (Test-Path -LiteralPath $existingPathFull -PathType Leaf)) {
            throw "Native hardlink source does not exist: $existingPathFull"
        }
        if (Test-Path -LiteralPath $newPathFull) {
            throw "Native hardlink destination already exists: $newPathFull"
        }

        [CanonicalNativeHardLink]::Create($newPathFull, $existingPathFull)

        if (-not (Test-Path -LiteralPath $newPathFull -PathType Leaf)) {
            throw "CreateHardLinkW returned success but destination is not visible: $newPathFull"
        }

        return Get-Item -LiteralPath $newPathFull
    }

    $forward = @{}
    if ($PSBoundParameters.ContainsKey("Path")) { $forward.Path = $Path }
    if ($PSBoundParameters.ContainsKey("ItemType")) { $forward.ItemType = $ItemType }
    if ($PSBoundParameters.ContainsKey("Value")) { $forward.Value = $Value }
    if ($Force) { $forward.Force = $true }

    return Microsoft.PowerShell.Management\New-Item @forward
}

$pilotPath = Join-Path $PSScriptRoot "14-cross-series-canonical-hardlink-pilot.ps1"
if (-not (Test-Path -LiteralPath $pilotPath -PathType Leaf)) {
    throw "Base experiment 14 not found: $pilotPath"
}

Write-Host ""
Write-Host "=== Native Hardlink Wrapper ==="
Write-Host "Base experiment: 14-cross-series-canonical-hardlink-pilot.ps1"
Write-Host "Hardlink method:  Windows CreateHardLinkW"
Write-Host ""

$pilotParams = @{
    ApiKey                    = $ApiKey
    Server                    = $Server
    RunLogPath                = $RunLogPath
    StagingRoot               = $StagingRoot
    PollIntervalSeconds       = $PollIntervalSeconds
    RemovalTimeoutSeconds     = $RemovalTimeoutSeconds
    ObservationTimeoutSeconds = $ObservationTimeoutSeconds
    RestoreTimeoutSeconds     = $RestoreTimeoutSeconds
    StableSamples             = $StableSamples
}
if ($Apply) { $pilotParams.Apply = $true }

& $pilotPath @pilotParams
