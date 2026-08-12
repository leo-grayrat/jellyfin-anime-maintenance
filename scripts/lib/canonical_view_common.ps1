$ErrorActionPreference = "Stop"

function Get-CvPathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
    }
    catch {
        return $Path.Trim().TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
    }
}

function Get-CvVolumeRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path must not be empty."
    }

    $normalized = $Path.Trim().Replace('/', '\')

    if ($normalized -match '^\\\\\?\\UNC\\([^\\]+)\\([^\\]+)(?:\\|$)') {
        return "\\$($Matches[1])\$($Matches[2])\"
    }

    if ($normalized -match '^\\\\\?\\([A-Za-z]:)\\') {
        return $Matches[1].ToUpperInvariant() + '\'
    }

    if ($normalized -match '^([A-Za-z]:)\\') {
        return $Matches[1].ToUpperInvariant() + '\'
    }

    if ($normalized -match '^\\\\([^\\]+)\\([^\\]+)(?:\\|$)') {
        return "\\$($Matches[1])\$($Matches[2])\"
    }

    throw "Unsupported Windows absolute path: $Path"
}

function Get-CvEpisodeKey {
    param(
        [Parameter(Mandatory = $true)][int]$Season,
        [Parameter(Mandatory = $true)][int]$Episode
    )

    return "S{0:D2}E{1:D2}" -f $Season, $Episode
}

function Get-CvCorrectionTargets {
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [int]$ExpectedCount = 243
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Correction CSV not found: $CsvPath"
    }

    $rows = @(Import-Csv -LiteralPath $CsvPath)
    $byPath = @{}

    foreach ($row in $rows) {
        if ([string]$row.RuleId -eq "series-nfo") { continue }
        if ([string]$row.Action -ne "WRITE") { continue }
        if ([string]::IsNullOrWhiteSpace([string]$row.VideoPath)) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$row.Season)) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$row.Episode)) { continue }

        $videoPath = [System.IO.Path]::GetFullPath([string]$row.VideoPath)
        $pathKey = Get-CvPathKey -Path $videoPath
        $season = [int]$row.Season
        $episode = [int]$row.Episode

        if ($byPath.ContainsKey($pathKey)) {
            $existing = $byPath[$pathKey]
            if ([int]$existing.TargetSeason -ne $season -or [int]$existing.TargetEpisode -ne $episode) {
                throw "Conflicting correction targets for path: $videoPath"
            }
            continue
        }

        $byPath[$pathKey] = [pscustomobject]@{
            Work          = [string]$row.Work
            RuleId        = [string]$row.RuleId
            VideoPath     = $videoPath
            PathKey       = $pathKey
            TargetSeason  = $season
            TargetEpisode = $episode
            ExpectedKey   = Get-CvEpisodeKey -Season $season -Episode $episode
        }
    }

    $targets = @($byPath.Values | Sort-Object VideoPath)
    if ($ExpectedCount -ge 0 -and $targets.Count -ne $ExpectedCount) {
        throw "Expected exactly $ExpectedCount correction targets, found $($targets.Count)."
    }

    return $targets
}

function Get-CvNfoIdentity {
    param([Parameter(Mandatory = $true)][string]$NfoPath)

    if (-not (Test-Path -LiteralPath $NfoPath -PathType Leaf)) {
        throw "NFO not found: $NfoPath"
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $NfoPath -Raw
    }
    catch {
        throw "NFO is not valid XML: $NfoPath :: $($_.Exception.Message)"
    }

    $seasonNode = $xml.SelectSingleNode("//season")
    $episodeNode = $xml.SelectSingleNode("//episode")

    if ($null -eq $seasonNode -or [string]::IsNullOrWhiteSpace([string]$seasonNode.InnerText)) {
        throw "NFO is missing <season>: $NfoPath"
    }
    if ($null -eq $episodeNode -or [string]::IsNullOrWhiteSpace([string]$episodeNode.InnerText)) {
        throw "NFO is missing <episode>: $NfoPath"
    }

    return [pscustomobject]@{
        Season  = [int]$seasonNode.InnerText
        Episode = [int]$episodeNode.InnerText
    }
}

function Get-CvRelativeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$LibraryRoot
    )

    $sourceFull = ([System.IO.Path]::GetFullPath($SourceDirectory)).TrimEnd([char[]]@('\', '/'))
    $rootFull = ([System.IO.Path]::GetFullPath($LibraryRoot)).TrimEnd([char[]]@('\', '/'))

    if ([string]::Equals($sourceFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $sourceFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source directory is outside library root: source=$sourceFull root=$rootFull"
    }

    return $sourceFull.Substring($prefix.Length)
}

function Assert-CvSafePathSegment {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Label must not be empty."
    }

    if ($Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$Label contains invalid filename characters: $Value"
    }

    if ($Value.EndsWith(" ") -or $Value.EndsWith(".")) {
        throw "$Label may not end with a space or period: $Value"
    }
}

function Get-CvCanonicalPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ViewRoot,
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [string]$RelativeDirectory = "",
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [Parameter(Mandatory = $true)][string]$NfoPath,
        [Parameter(Mandatory = $true)][string]$ExpectedKey
    )

    Assert-CvSafePathSegment -Value $LibraryName -Label "LibraryName"

    if ($ExpectedKey -notmatch '^S[0-9]+E[0-9]+$') {
        throw "Invalid canonical episode key: $ExpectedKey"
    }

    $baseDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($ViewRoot), $LibraryName)
    if (-not [string]::IsNullOrWhiteSpace($RelativeDirectory)) {
        $baseDirectory = [System.IO.Path]::Combine($baseDirectory, $RelativeDirectory)
    }

    $videoName = "$ExpectedKey - $([System.IO.Path]::GetFileName($VideoPath))"
    $nfoName = "$ExpectedKey - $([System.IO.Path]::GetFileName($NfoPath))"

    return [pscustomobject]@{
        Directory = $baseDirectory
        Video     = [System.IO.Path]::Combine($baseDirectory, $videoName)
        Nfo       = [System.IO.Path]::Combine($baseDirectory, $nfoName)
    }
}

function Get-CvManifestIndex {
    param([object[]]$Rows = @())

    $index = @{}

    foreach ($row in @($Rows)) {
        foreach ($column in @("CanonicalVideo", "CanonicalNfo")) {
            $path = [string]$row.$column
            if ([string]::IsNullOrWhiteSpace($path)) { continue }

            $key = Get-CvPathKey -Path $path
            if ($index.ContainsKey($key)) {
                throw "Duplicate canonical path in manifest: $path"
            }
            $index[$key] = $row
        }
    }

    return $index
}

function Test-CvExistingTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$ManifestIndex,
        [Parameter(Mandatory = $true)][string]$ManifestSourceColumn,
        [long]$ExpectedLength = -1
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        return [pscustomobject]@{ State = "MISSING"; Reason = "target does not exist" }
    }

    $targetKey = Get-CvPathKey -Path $TargetPath
    if (-not $ManifestIndex.ContainsKey($targetKey)) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "target exists but is not manifest-managed" }
    }

    $row = $ManifestIndex[$targetKey]
    if ($null -eq $row.PSObject.Properties[$ManifestSourceColumn]) {
        throw "Manifest source column does not exist: $ManifestSourceColumn"
    }

    $managedSource = [string]$row.$ManifestSourceColumn
    if ((Get-CvPathKey -Path $managedSource) -ne (Get-CvPathKey -Path $SourcePath)) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "manifest source does not match current source" }
    }

    if ($ExpectedLength -ge 0) {
        $actualLength = (Get-Item -LiteralPath $TargetPath).Length
        if ([long]$actualLength -ne $ExpectedLength) {
            return [pscustomobject]@{ State = "CONFLICT"; Reason = "target length does not match source length" }
        }
    }

    return [pscustomobject]@{ State = "REUSABLE"; Reason = "manifest-managed same source" }
}

function Initialize-CvNativeHardLink {
    if ("CvNativeHardLink" -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CvNativeHardLink
{
    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(
        string lpFileName,
        string lpExistingFileName,
        IntPtr lpSecurityAttributes);

    private static string ToExtendedPath(string path)
    {
        if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }
        if (path.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return @"\\?\UNC\" + path.Substring(2);
        }
        return @"\\?\" + path;
    }

    public static void Create(string newPath, string existingPath)
    {
        if (!CreateHardLinkW(ToExtendedPath(newPath), ToExtendedPath(existingPath), IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

function New-CvNativeHardLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $newPath = [System.IO.Path]::GetFullPath($Path)
    $existingPath = [System.IO.Path]::GetFullPath($Target)

    if (-not (Test-Path -LiteralPath $existingPath -PathType Leaf)) {
        throw "Hardlink source does not exist: $existingPath"
    }
    if (Test-Path -LiteralPath $newPath) {
        throw "Hardlink destination already exists: $newPath"
    }

    $parent = [System.IO.Path]::GetDirectoryName($newPath)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Hardlink destination directory does not exist: $parent"
    }

    $sourceRoot = Get-CvVolumeRoot -Path $existingPath
    $targetRoot = Get-CvVolumeRoot -Path $newPath
    if (-not [string]::Equals($sourceRoot, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Hardlink source and destination are on different volumes: source=$sourceRoot target=$targetRoot"
    }

    Initialize-CvNativeHardLink
    [CvNativeHardLink]::Create($newPath, $existingPath)

    if (-not (Test-Path -LiteralPath $newPath -PathType Leaf)) {
        throw "CreateHardLinkW returned success but destination is not visible: $newPath"
    }

    $sourceLength = (Get-Item -LiteralPath $existingPath).Length
    $targetLength = (Get-Item -LiteralPath $newPath).Length
    if ([long]$sourceLength -ne [long]$targetLength) {
        throw "Hardlink length mismatch: source=$sourceLength target=$targetLength"
    }

    return Get-Item -LiteralPath $newPath
}
