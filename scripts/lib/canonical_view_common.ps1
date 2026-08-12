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

function Get-CvLibraryLocations {
    param([Parameter(Mandatory = $true)]$VirtualFolders)

    $locations = @()
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($VirtualFolders)

    while ($pending.Count -gt 0) {
        $value = $pending.Dequeue()
        if ($null -eq $value) { continue }

        $hasName = $null -ne $value.PSObject.Properties['Name']
        $hasLocations = $null -ne $value.PSObject.Properties['Locations']

        if ($hasName -and $hasLocations) {
            $libraryName = [string]$value.Name
            foreach ($location in $value.Locations) {
                if ([string]::IsNullOrWhiteSpace([string]$location)) { continue }
                $locations += [pscustomobject]@{
                    LibraryName = $libraryName
                    Root        = [System.IO.Path]::GetFullPath([string]$location)
                }
            }
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            foreach ($item in $value) {
                $pending.Enqueue($item)
            }
            continue
        }

        throw "Unexpected Jellyfin virtual-folder response item: $($value.GetType().FullName)"
    }

    return @($locations)
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

function Merge-CvManifestRows {
    param(
        [object[]]$ExistingRows = @(),
        [object[]]$NewRows = @()
    )

    $byCanonicalVideo = @{}

    foreach ($row in @($ExistingRows)) {
        $canonicalVideo = [string]$row.CanonicalVideo
        if ([string]::IsNullOrWhiteSpace($canonicalVideo)) {
            throw "Existing manifest row is missing CanonicalVideo."
        }
        $key = Get-CvPathKey -Path $canonicalVideo
        if ($byCanonicalVideo.ContainsKey($key)) {
            throw "Duplicate CanonicalVideo in existing manifest: $canonicalVideo"
        }
        $byCanonicalVideo[$key] = $row
    }

    foreach ($row in @($NewRows)) {
        $canonicalVideo = [string]$row.CanonicalVideo
        if ([string]::IsNullOrWhiteSpace($canonicalVideo)) {
            throw "New manifest row is missing CanonicalVideo."
        }
        $key = Get-CvPathKey -Path $canonicalVideo
        $byCanonicalVideo[$key] = $row
    }

    return @($byCanonicalVideo.Values | Sort-Object CanonicalVideo)
}

function Get-CvRollbackPaths {
    param([object[]]$BuildRows = @())

    $paths = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($row in @($BuildRows)) {
        if ([string]$row.NfoResult -eq "CREATED" -and -not [string]::IsNullOrWhiteSpace([string]$row.CanonicalNfo)) {
            $key = Get-CvPathKey -Path ([string]$row.CanonicalNfo)
            if (-not $seen.ContainsKey($key)) {
                [void]$paths.Add([string]$row.CanonicalNfo)
                $seen[$key] = $true
            }
        }

        if ([string]$row.VideoResult -eq "CREATED" -and -not [string]::IsNullOrWhiteSpace([string]$row.CanonicalVideo)) {
            $key = Get-CvPathKey -Path ([string]$row.CanonicalVideo)
            if (-not $seen.ContainsKey($key)) {
                [void]$paths.Add([string]$row.CanonicalVideo)
                $seen[$key] = $true
            }
        }
    }

    return @($paths)
}

function Initialize-CvNativeHardLink {
    if ("CvNativeFileSystem" -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CvNativeFileSystem
{
    private const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    private const uint FILE_SHARE_READ = 0x1;
    private const uint FILE_SHARE_WRITE = 0x2;
    private const uint FILE_SHARE_DELETE = 0x4;
    private const uint OPEN_EXISTING = 3;
    private const uint MOVEFILE_REPLACE_EXISTING = 0x1;
    private const uint MOVEFILE_WRITE_THROUGH = 0x8;
    private const int ERROR_FILE_NOT_FOUND = 2;
    private const int ERROR_PATH_NOT_FOUND = 3;
    private const int ERROR_ALREADY_EXISTS = 183;
    private const int ERROR_DIR_NOT_EMPTY = 145;

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string lpFileName);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectoryW(string lpPathName, IntPtr lpSecurityAttributes);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CopyFileW(string lpExistingFileName, string lpNewFileName, bool bFailIfExists);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string lpFileName);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool RemoveDirectoryW(string lpPathName);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileExW(string lpExistingFileName, string lpNewFileName, uint dwFlags);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("Kernel32.dll", SetLastError = true)]
    private static extern bool GetFileSizeEx(IntPtr hFile, out long lpFileSize);

    [DllImport("Kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

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

    public static bool FileExists(string path)
    {
        uint attributes = GetFileAttributesW(ToExtendedPath(path));
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }

    public static bool DirectoryExists(string path)
    {
        uint attributes = GetFileAttributesW(ToExtendedPath(path));
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    }

    public static long GetLength(string path)
    {
        IntPtr handle = CreateFileW(
            ToExtendedPath(path),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            long length;
            if (!GetFileSizeEx(handle, out length))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return length;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    public static void CreateHardLink(string newPath, string existingPath)
    {
        if (!CreateHardLinkW(ToExtendedPath(newPath), ToExtendedPath(existingPath), IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void CreateDirectoryOne(string path)
    {
        if (DirectoryExists(path))
        {
            return;
        }

        if (!CreateDirectoryW(ToExtendedPath(path), IntPtr.Zero))
        {
            int error = Marshal.GetLastWin32Error();
            if (error != ERROR_ALREADY_EXISTS)
            {
                throw new Win32Exception(error);
            }
        }
    }

    public static void CopyFile(string source, string destination, bool overwrite)
    {
        if (!CopyFileW(ToExtendedPath(source), ToExtendedPath(destination), !overwrite))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void DeleteFileIfExists(string path)
    {
        if (!FileExists(path))
        {
            return;
        }

        if (!DeleteFileW(ToExtendedPath(path)))
        {
            int error = Marshal.GetLastWin32Error();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
            {
                throw new Win32Exception(error);
            }
        }
    }

    public static bool RemoveDirectoryIfEmpty(string path)
    {
        if (!DirectoryExists(path))
        {
            return true;
        }

        if (RemoveDirectoryW(ToExtendedPath(path)))
        {
            return true;
        }

        int error = Marshal.GetLastWin32Error();
        if (error == ERROR_DIR_NOT_EMPTY)
        {
            return false;
        }
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
        {
            return true;
        }
        throw new Win32Exception(error);
    }

    public static void MoveReplace(string source, string destination)
    {
        uint flags = MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH;
        if (!MoveFileExW(ToExtendedPath(source), ToExtendedPath(destination), flags))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

function Test-CvNativeFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [CvNativeFileSystem]::FileExists([System.IO.Path]::GetFullPath($Path))
}

function Test-CvNativeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [CvNativeFileSystem]::DirectoryExists([System.IO.Path]::GetFullPath($Path))
}

function Get-CvNativeFileLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [long][CvNativeFileSystem]::GetLength([System.IO.Path]::GetFullPath($Path))
}

function New-CvNativeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CreateDirectoryOne($fullPath)
}

function New-CvNativeDirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/'))
    $root = Get-CvVolumeRoot -Path $fullPath

    if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Directory path is outside its parsed volume root: $fullPath"
    }

    $relative = $fullPath.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return @()
    }

    $current = $root.TrimEnd([char[]]@('\', '/'))
    $created = New-Object System.Collections.ArrayList

    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        if ($current.EndsWith(':')) {
            $current += '\' + $segment
        }
        else {
            $current += '\' + $segment
        }

        if (-not (Test-CvNativeDirectory -Path $current)) {
            New-CvNativeDirectory -Path $current
            [void]$created.Add($current)
        }
    }

    return @($created)
}

function Copy-CvNativeFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite
    )

    $sourceFull = [System.IO.Path]::GetFullPath($Source)
    $destinationFull = [System.IO.Path]::GetFullPath($Destination)

    if (-not (Test-CvNativeFile -Path $sourceFull)) {
        throw "Copy source does not exist: $sourceFull"
    }

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CopyFile($sourceFull, $destinationFull, [bool]$Overwrite)

    if (-not (Test-CvNativeFile -Path $destinationFull)) {
        throw "Native copy returned success but destination is not visible: $destinationFull"
    }
}

function Remove-CvNativeFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::DeleteFileIfExists([System.IO.Path]::GetFullPath($Path))
}

function Remove-CvNativeDirectoryIfEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [bool][CvNativeFileSystem]::RemoveDirectoryIfEmpty([System.IO.Path]::GetFullPath($Path))
}

function Move-CvNativeFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::MoveReplace(
        [System.IO.Path]::GetFullPath($Source),
        [System.IO.Path]::GetFullPath($Destination))
}

function Test-CvExistingTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$ManifestIndex,
        [Parameter(Mandatory = $true)][string]$ManifestSourceColumn,
        [long]$ExpectedLength = -1
    )

    if (-not (Test-CvNativeFile -Path $TargetPath)) {
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
        $actualLength = Get-CvNativeFileLength -Path $TargetPath
        if ([long]$actualLength -ne $ExpectedLength) {
            return [pscustomobject]@{ State = "CONFLICT"; Reason = "target length does not match source length" }
        }
    }

    return [pscustomobject]@{ State = "REUSABLE"; Reason = "manifest-managed same source" }
}

function New-CvNativeHardLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $newPath = [System.IO.Path]::GetFullPath($Path)
    $existingPath = [System.IO.Path]::GetFullPath($Target)

    if (-not (Test-CvNativeFile -Path $existingPath)) {
        throw "Hardlink source does not exist: $existingPath"
    }
    if (Test-CvNativeFile -Path $newPath) {
        throw "Hardlink destination already exists: $newPath"
    }

    $lastBackslash = $newPath.LastIndexOf('\')
    $lastSlash = $newPath.LastIndexOf('/')
    $lastSeparator = [Math]::Max($lastBackslash, $lastSlash)
    if ($lastSeparator -lt 1) {
        throw "Hardlink destination has no parent directory: $newPath"
    }
    $parent = $newPath.Substring(0, $lastSeparator)
    if (-not (Test-CvNativeDirectory -Path $parent)) {
        throw "Hardlink destination directory does not exist: $parent"
    }

    $sourceRoot = Get-CvVolumeRoot -Path $existingPath
    $targetRoot = Get-CvVolumeRoot -Path $newPath
    if (-not [string]::Equals($sourceRoot, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Hardlink source and destination are on different volumes: source=$sourceRoot target=$targetRoot"
    }

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CreateHardLink($newPath, $existingPath)

    if (-not (Test-CvNativeFile -Path $newPath)) {
        throw "CreateHardLinkW returned success but destination is not visible: $newPath"
    }

    $sourceLength = Get-CvNativeFileLength -Path $existingPath
    $targetLength = Get-CvNativeFileLength -Path $newPath
    if ([long]$sourceLength -ne [long]$targetLength) {
        throw "Hardlink length mismatch: source=$sourceLength target=$targetLength"
    }

    return [pscustomobject]@{
        Path   = $newPath
        Length = $targetLength
    }
}