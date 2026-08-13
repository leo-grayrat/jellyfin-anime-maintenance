[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$Output = "$env:USERPROFILE\Desktop\jellyfin-tv-audit-export.json"
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

. (Join-Path $PSScriptRoot "lib\tv_audit_common.ps1")

$Headers = @{
    Authorization = "MediaBrowser Client=`"tv-audit-export`", Device=`"PowerShell`", DeviceId=`"tv-audit-export`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-TvaJellyfinGet {
    param([Parameter(Mandatory = $true)][string]$Uri)

    return Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $Headers `
        -ErrorAction Stop
}

function Add-TvaLibraryContext {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$LibraryItemId
    )

    if ($null -eq $Item.PSObject.Properties['LibraryName']) {
        $Item | Add-Member -NotePropertyName LibraryName -NotePropertyValue $LibraryName
    }
    else {
        $Item.LibraryName = $LibraryName
    }

    if ($null -eq $Item.PSObject.Properties['LibraryItemId']) {
        $Item | Add-Member -NotePropertyName LibraryItemId -NotePropertyValue $LibraryItemId
    }
    else {
        $Item.LibraryItemId = $LibraryItemId
    }

    return $Item
}

function Get-TvaPagedItems {
    param(
        [string]$LibraryItemId = "",
        [string]$LibraryName = "",
        [Parameter(Mandatory = $true)][string]$IncludeItemTypes,
        [switch]$ExpandedVideoFiles
    )

    $startIndex = 0
    $limit = 500
    $allItems = @()

    $fields = @(
        "Path",
        "ProviderIds",
        "Overview",
        "DateCreated",
        "OriginalTitle",
        "SortName",
        "MediaSources",
        "MediaSourceCount",
        "ParentId",
        "DateLastRefreshed",
        "DateLastSaved",
        "RefreshState"
    ) -join ","

    do {
        $query = @(
            "Recursive=true",
            ("StartIndex={0}" -f $startIndex),
            ("Limit={0}" -f $limit),
            ("IncludeItemTypes={0}" -f [uri]::EscapeDataString($IncludeItemTypes)),
            ("Fields={0}" -f [uri]::EscapeDataString($fields)),
            "EnableImages=true",
            "ImageTypeLimit=1",
            "EnableUserData=false"
        )

        if (-not [string]::IsNullOrWhiteSpace($LibraryItemId)) {
            $query += ("ParentId={0}" -f [uri]::EscapeDataString($LibraryItemId))
        }

        if ($ExpandedVideoFiles) {
            $query += "VideoTypes=VideoFile"
        }

        $uri = "$Server/Items?" + ($query -join "&")
        $response = Invoke-TvaJellyfinGet -Uri $uri
        $page = @($response.Items)

        foreach ($item in $page) {
            if (-not [string]::IsNullOrWhiteSpace($LibraryName)) {
                [void](Add-TvaLibraryContext -Item $item -LibraryName $LibraryName -LibraryItemId $LibraryItemId)
            }
            $allItems += $item
        }

        $startIndex += $page.Count
    } while ($page.Count -gt 0 -and $startIndex -lt [int]$response.TotalRecordCount)

    return @($allItems)
}

function Get-TvaPathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Trim().Replace('/', '\').TrimEnd([char[]]@('\')).ToLowerInvariant()
}

function Test-TvaPathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $pathKey = Get-TvaPathKey -Path $Path
    $rootKey = Get-TvaPathKey -Path $Root
    if ([string]::IsNullOrWhiteSpace($pathKey) -or [string]::IsNullOrWhiteSpace($rootKey)) {
        return $false
    }

    if ($pathKey -eq $rootKey) { return $true }
    return $pathKey.StartsWith($rootKey + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-TvaExpandedLibrary {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$SeriesLibraryIndex,
        [Parameter(Mandatory = $true)][object[]]$LibraryRoots
    )

    $seriesId = [string]$Item.SeriesId
    if (-not [string]::IsNullOrWhiteSpace($seriesId) -and $SeriesLibraryIndex.ContainsKey($seriesId)) {
        return $SeriesLibraryIndex[$seriesId]
    }

    $path = [string]$Item.Path
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        foreach ($root in $LibraryRoots) {
            if (Test-TvaPathUnderRoot -Path $path -Root ([string]$root.Root)) {
                return $root
            }
        }
    }

    return $null
}

Write-Host ""
Write-Host "=== Jellyfin TV Audit Export ==="
Write-Host "Mode: READ ONLY"
Write-Host "Server: $Server"
Write-Host ""

Write-Host "[1/5] Reading server and TV library configuration..."
$systemInfo = Invoke-TvaJellyfinGet -Uri "$Server/System/Info"
$virtualFolders = Invoke-TvaJellyfinGet -Uri "$Server/Library/VirtualFolders"
$tvLibraries = @(Get-TvaTvLibraries -VirtualFolders $virtualFolders)

if ($tvLibraries.Count -eq 0) {
    throw "No tvshows libraries found."
}

foreach ($library in $tvLibraries) {
    if ([string]$library.CollectionType -ne "tvshows") {
        throw "Non-TV library escaped TV-only filtering."
    }
}

Write-Host ("Server version: {0}" -f [string]$systemInfo.Version)
Write-Host ("TV libraries: {0}" -f $tvLibraries.Count)

$normalItems = @()
$seriesLibraryIndex = @{}
$libraryRoots = @()

Write-Host ""
Write-Host "[2/5] Reading normal Series, Season, and Episode items per TV library..."
foreach ($library in $tvLibraries) {
    $libraryName = [string]$library.Name
    $libraryItemId = [string]$library.ItemId

    if ([string]::IsNullOrWhiteSpace($libraryItemId)) {
        throw "TV library is missing ItemId: $libraryName"
    }

    $items = @(Get-TvaPagedItems `
        -LibraryItemId $libraryItemId `
        -LibraryName $libraryName `
        -IncludeItemTypes "Series,Season,Episode")

    $normalItems += $items

    foreach ($series in @($items | Where-Object { [string]$_.Type -eq "Series" })) {
        $seriesId = [string]$series.Id
        if (-not [string]::IsNullOrWhiteSpace($seriesId) -and -not $seriesLibraryIndex.ContainsKey($seriesId)) {
            $seriesLibraryIndex[$seriesId] = [pscustomobject]@{
                LibraryName   = $libraryName
                LibraryItemId = $libraryItemId
            }
        }
    }

    foreach ($location in @($library.Locations)) {
        if ([string]::IsNullOrWhiteSpace([string]$location)) { continue }
        $libraryRoots += [pscustomobject]@{
            LibraryName   = $libraryName
            LibraryItemId = $libraryItemId
            Root          = [string]$location
        }
    }

    Write-Host ("  {0}: {1} normal items" -f $libraryName, $items.Count)
}

Write-Host ""
Write-Host "[3/5] Reading expanded Episode view, including hidden local alternates..."
$expandedGlobal = @(Get-TvaPagedItems -IncludeItemTypes "Episode" -ExpandedVideoFiles)
$expandedEpisodes = @()

foreach ($item in $expandedGlobal) {
    $libraryContext = Resolve-TvaExpandedLibrary `
        -Item $item `
        -SeriesLibraryIndex $seriesLibraryIndex `
        -LibraryRoots $libraryRoots

    if ($null -eq $libraryContext) { continue }

    [void](Add-TvaLibraryContext `
        -Item $item `
        -LibraryName ([string]$libraryContext.LibraryName) `
        -LibraryItemId ([string]$libraryContext.LibraryItemId))

    $expandedEpisodes += $item
}

$normalEpisodeCount = @($normalItems | Where-Object { [string]$_.Type -eq "Episode" }).Count
if ($expandedEpisodes.Count -lt $normalEpisodeCount) {
    throw ("Expanded Episode view is unexpectedly smaller than the normal Episode view: expanded={0}, normal={1}" -f $expandedEpisodes.Count, $normalEpisodeCount)
}

Write-Host ("Expanded Episodes kept in TV scope: {0}" -f $expandedEpisodes.Count)

Write-Host ""
Write-Host "[4/5] Inventorying TV filesystem and same-name NFO files..."
$filesystemVideos = @()
$scannedRoots = @{}

foreach ($root in $libraryRoots) {
    $rootKey = ([string]$root.LibraryName).ToLowerInvariant() + "|" + (Get-TvaPathKey -Path ([string]$root.Root))
    if ($scannedRoots.ContainsKey($rootKey)) { continue }
    $scannedRoots[$rootKey] = $true

    Write-Host ("  Scanning [{0}] {1}" -f [string]$root.LibraryName, [string]$root.Root)
    $files = @(Get-TvaVideoFiles -LibraryName ([string]$root.LibraryName) -LibraryRoot ([string]$root.Root))
    $filesystemVideos += $files
    Write-Host ("    Video files: {0}" -f $files.Count)
}

Write-Host ""
Write-Host "[5/5] Serializing audit snapshot..."

$export = [ordered]@{
    SchemaVersion = 1
    ExportedAt = (Get-Date).ToString("o")
    Server = [ordered]@{
        Version = [string]$systemInfo.Version
        ProductName = [string]$systemInfo.ProductName
        ServerName = [string]$systemInfo.ServerName
    }
    TvLibraries = @($tvLibraries)
    NormalItems = @($normalItems)
    ExpandedEpisodes = @($expandedEpisodes)
    FilesystemVideos = @($filesystemVideos)
}

$outputFull = [System.IO.Path]::GetFullPath($Output)
$outputDirectory = [System.IO.Path]::GetDirectoryName($outputFull)
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    throw "Could not determine output directory: $Output"
}

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$tempOutput = $outputFull + ".tmp-" + [guid]::NewGuid().ToString("N")

try {
    $json = $export | ConvertTo-Json -Depth 50

    if (-not [string]::IsNullOrEmpty($ApiKey) -and $json.Contains($ApiKey)) {
        throw "Refusing to write export because API key text appeared in serialized JSON."
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempOutput, $json, $utf8NoBom)

    if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
        Remove-Item -LiteralPath $outputFull -Force
    }
    Move-Item -LiteralPath $tempOutput -Destination $outputFull
}
finally {
    if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
        Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ("TV libraries:        {0}" -f $tvLibraries.Count)
Write-Host ("Normal items:        {0}" -f $normalItems.Count)
Write-Host ("Normal Episodes:     {0}" -f $normalEpisodeCount)
Write-Host ("Expanded Episodes:   {0}" -f $expandedEpisodes.Count)
Write-Host ("Filesystem videos:   {0}" -f $filesystemVideos.Count)
Write-Host ("Output:               {0}" -f $outputFull)
Write-Host ""
Write-Host "READ ONLY: no Jellyfin metadata, NFO, media file, or database was changed."
