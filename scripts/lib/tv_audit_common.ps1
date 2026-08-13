$ErrorActionPreference = "Stop"

function Get-TvaTvLibraries {
    param([Parameter(Mandatory = $true)]$VirtualFolders)

    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($VirtualFolders)

    while ($queue.Count -gt 0) {
        $value = $queue.Dequeue()
        if ($null -eq $value) { continue }

        $hasName = $null -ne $value.PSObject.Properties['Name']
        $hasType = $null -ne $value.PSObject.Properties['CollectionType']
        $hasLocations = $null -ne $value.PSObject.Properties['Locations']

        if ($hasName -and $hasType -and $hasLocations) {
            if ([string]$value.CollectionType -eq "tvshows") {
                $result += $value
            }
            continue
        }

        $valueProperty = $value.PSObject.Properties['value']
        if ($null -ne $valueProperty) {
            $queue.Enqueue($valueProperty.Value)
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            foreach ($item in $value) {
                $queue.Enqueue($item)
            }
            continue
        }

        throw "Unexpected Jellyfin virtual-folder response shape."
    }

    return @($result | Sort-Object Name)
}

function Get-TvaPathExtension {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    $lastSlash = [Math]::Max($Path.LastIndexOf('\'), $Path.LastIndexOf('/'))
    $lastDot = $Path.LastIndexOf('.')
    if ($lastDot -lt 0 -or $lastDot -le $lastSlash -or $lastDot -eq ($Path.Length - 1)) {
        return ""
    }

    return $Path.Substring($lastDot).ToLowerInvariant()
}

function Test-TvaVideoExtension {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = Get-TvaPathExtension -Path $Path
    if ([string]::IsNullOrWhiteSpace($extension)) { return $false }

    return @(".mkv", ".mp4", ".m4v", ".avi", ".ts", ".webm") -contains $extension
}

function Initialize-TvaNativeFileSystem {
    if ("TvaNativeFileSystem" -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class TvaFileEntry
{
    public string Path { get; set; }
    public long Length { get; set; }
    public DateTime LastWriteTimeUtc { get; set; }
}

public static class TvaNativeFileSystem
{
    private const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATA lpFindFileData);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);

    [DllImport("Kernel32.dll", SetLastError = true)]
    private static extern bool FindClose(IntPtr hFindFile);

    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string lpFileName);

    private static string ToExtendedPath(string path)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("Path must not be empty.", "path");
        }

        string normalized = path.Replace('/', '\\');
        if (normalized.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
        {
            return normalized;
        }
        if (normalized.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return @"\\?\UNC\" + normalized.Substring(2);
        }
        return @"\\?\" + normalized;
    }

    private static string CombinePath(string directory, string name)
    {
        return directory.TrimEnd('\\') + "\\" + name;
    }

    private static DateTime FileTimeToUtc(System.Runtime.InteropServices.ComTypes.FILETIME value)
    {
        long fileTime = ((long)value.dwHighDateTime << 32) | (uint)value.dwLowDateTime;
        return DateTime.FromFileTimeUtc(fileTime);
    }

    private static long GetLength(WIN32_FIND_DATA data)
    {
        return ((long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
    }

    private static void EnumerateDirectory(string logicalDirectory, List<TvaFileEntry> result)
    {
        string search = ToExtendedPath(CombinePath(logicalDirectory, "*"));
        WIN32_FIND_DATA data;
        IntPtr handle = FindFirstFileW(search, out data);
        if (handle == INVALID_HANDLE_VALUE)
        {
            int error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, "FindFirstFileW failed for " + logicalDirectory);
        }

        try
        {
            bool more = true;
            while (more)
            {
                string name = data.cFileName;
                if (name != "." && name != "..")
                {
                    string child = CombinePath(logicalDirectory, name);
                    bool isDirectory = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    bool isReparsePoint = (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                    if (isDirectory)
                    {
                        if (!isReparsePoint)
                        {
                            EnumerateDirectory(child, result);
                        }
                    }
                    else
                    {
                        result.Add(new TvaFileEntry
                        {
                            Path = child,
                            Length = GetLength(data),
                            LastWriteTimeUtc = FileTimeToUtc(data.ftLastWriteTime)
                        });
                    }
                }

                more = FindNextFileW(handle, out data);
                if (!more)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != 18)
                    {
                        throw new Win32Exception(error, "FindNextFileW failed for " + logicalDirectory);
                    }
                }
            }
        }
        finally
        {
            FindClose(handle);
        }
    }

    public static TvaFileEntry[] EnumerateFilesRecursive(string root)
    {
        List<TvaFileEntry> result = new List<TvaFileEntry>();
        EnumerateDirectory(root.TrimEnd('\\', '/'), result);
        return result.ToArray();
    }

    public static bool FileExists(string path)
    {
        uint attributes = GetFileAttributesW(ToExtendedPath(path));
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }

    public static string ReadAllText(string path)
    {
        string extended = ToExtendedPath(path);
        using (FileStream stream = new FileStream(extended, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
        {
            return reader.ReadToEnd();
        }
    }
}
"@
}

function Get-TvaNfoSummaryFromText {
    param([Parameter(Mandatory = $true)][string]$XmlText)

    [xml]$xml = $XmlText

    $root = $xml.DocumentElement
    if ($null -eq $root) {
        throw "NFO XML has no document element."
    }

    $season = $null
    $episode = $null
    $title = ""
    $plot = ""

    $seasonNode = $xml.SelectSingleNode("//season")
    if ($null -ne $seasonNode -and -not [string]::IsNullOrWhiteSpace([string]$seasonNode.InnerText)) {
        $season = [int]$seasonNode.InnerText
    }

    $episodeNode = $xml.SelectSingleNode("//episode")
    if ($null -ne $episodeNode -and -not [string]::IsNullOrWhiteSpace([string]$episodeNode.InnerText)) {
        $episode = [int]$episodeNode.InnerText
    }

    $titleNode = $xml.SelectSingleNode("//title")
    if ($null -ne $titleNode) {
        $title = [string]$titleNode.InnerText
    }

    $plotNode = $xml.SelectSingleNode("//plot")
    if ($null -ne $plotNode) {
        $plot = [string]$plotNode.InnerText
    }

    $uniqueIds = [ordered]@{}
    foreach ($node in @($xml.SelectNodes("//uniqueid"))) {
        if ($null -eq $node) { continue }
        $type = [string]$node.GetAttribute("type")
        $value = [string]$node.InnerText
        if ([string]::IsNullOrWhiteSpace($type) -or [string]::IsNullOrWhiteSpace($value)) { continue }
        $uniqueIds[$type.ToLowerInvariant()] = $value.Trim()
    }

    foreach ($legacyName in @("tmdbid", "tvdbid", "imdbid")) {
        $legacyNode = $xml.SelectSingleNode("//$legacyName")
        if ($null -eq $legacyNode -or [string]::IsNullOrWhiteSpace([string]$legacyNode.InnerText)) { continue }

        $key = $legacyName.Substring(0, $legacyName.Length - 2)
        if (-not $uniqueIds.Contains($key)) {
            $uniqueIds[$key] = ([string]$legacyNode.InnerText).Trim()
        }
    }

    return [pscustomobject]@{
        Season    = $season
        Episode   = $episode
        Title     = $title
        Plot      = $plot
        UniqueIds = [pscustomobject]$uniqueIds
    }
}

function Get-TvaNfoSummary {
    param([Parameter(Mandatory = $true)][string]$NfoPath)

    Initialize-TvaNativeFileSystem
    if (-not [TvaNativeFileSystem]::FileExists($NfoPath)) {
        throw "NFO not found: $NfoPath"
    }

    $text = [TvaNativeFileSystem]::ReadAllText($NfoPath)
    return Get-TvaNfoSummaryFromText -XmlText $text
}

function Get-TvaVideoFiles {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$LibraryRoot
    )

    Initialize-TvaNativeFileSystem

    $result = @()
    foreach ($entry in @([TvaNativeFileSystem]::EnumerateFilesRecursive($LibraryRoot))) {
        $entryPath = [string]$entry.Path
        if (-not (Test-TvaVideoExtension -Path $entryPath)) { continue }

        $extension = Get-TvaPathExtension -Path $entryPath
        $nfoPath = $entryPath.Substring(0, $entryPath.Length - $extension.Length) + ".nfo"
        $nfoExists = [TvaNativeFileSystem]::FileExists($nfoPath)
        $nfoSummary = $null
        $nfoError = ""

        if ($nfoExists) {
            try {
                $nfoSummary = Get-TvaNfoSummary -NfoPath $nfoPath
            }
            catch {
                $nfoError = $_.Exception.Message
            }
        }

        $result += [pscustomobject]@{
            LibraryName       = $LibraryName
            LibraryRoot       = $LibraryRoot
            Path              = $entryPath
            Extension         = $extension
            Length            = [long]$entry.Length
            LastWriteTime     = ([datetime]$entry.LastWriteTimeUtc).ToLocalTime().ToString("o")
            SameNameNfoPath   = $nfoPath
            SameNameNfoExists = [bool]$nfoExists
            NfoSummary        = $nfoSummary
            NfoReadError      = $nfoError
        }
    }

    return @($result | Sort-Object Path)
}
