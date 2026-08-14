# MEDALIST S02E01 METADATA REPLACEMENT PILOT
#
# Goal: isolate one question: does FullRefresh with replaceAllMetadata=true
# replace an already non-empty filename-fallback Episode Name after S/E is correct?
#
# Default: DRY RUN. -Apply is required for the single Jellyfin metadata refresh.
# The script does not change media files, NFO files, images, or the database directly.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [switch]$Apply,
    [int]$PollIntervalSeconds = 2,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($PollIntervalSeconds -lt 1) { throw "PollIntervalSeconds must be at least 1." }
if ($TimeoutSeconds -lt 20) { throw "TimeoutSeconds must be at least 20." }

$TargetItemId = "6993f67864a11e1151e7c9c6d3eee68d"
$TargetSeriesId = "1e343af25a95b525ae23adc50142693a"
$ExpectedSeason = 2
$ExpectedEpisode = 1
$ExpectedName = "Medalist"

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot "scripts\lib\tv_audit_common.ps1")

$Headers = @{
    Authorization = "MediaBrowser Client=`"metadata-replace-pilot`", Device=`"PowerShell`", DeviceId=`"metadata-replace-pilot`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-TargetItem {
    $fields = [uri]::EscapeDataString("Path,ProviderIds,Overview,Settings,OriginalTitle,SortName,MediaSourceCount")
    $uri = "$Server/Items?Ids=$TargetItemId&IncludeItemTypes=Episode&Recursive=true&Limit=1&Fields=$fields&EnableImages=true&ImageTypeLimit=1&EnableUserData=false"
    $response = Invoke-JfGet -Uri $uri
    $items = @($response.Items)
    if ($items.Count -ne 1) {
        throw ("Expected exactly one target Episode, got {0}." -f $items.Count)
    }
    return $items[0]
}

function Get-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Trim().Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    $pathKey = Get-PathKey -Path $Path
    $rootKey = Get-PathKey -Path $Root
    if ([string]::IsNullOrWhiteSpace($pathKey) -or [string]::IsNullOrWhiteSpace($rootKey)) { return $false }
    if ($pathKey -eq $rootKey) { return $true }
    return $pathKey.StartsWith($rootKey + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TargetLibrary {
    param([Parameter(Mandatory = $true)]$Item)

    $virtualFolders = Invoke-JfGet -Uri "$Server/Library/VirtualFolders"
    $tvLibraries = @(Get-TvaTvLibraries -VirtualFolders $virtualFolders)
    $matches = @()

    foreach ($library in $tvLibraries) {
        foreach ($location in @($library.Locations)) {
            if (Test-PathUnderRoot -Path ([string]$Item.Path) -Root ([string]$location)) {
                $matches += $library
                break
            }
        }
    }

    if ($matches.Count -ne 1) {
        throw ("Expected exactly one TV library for target path, got {0}." -f $matches.Count)
    }

    return $matches[0]
}

function Get-ProviderIdCount {
    param($Item)
    if ($null -eq $Item.ProviderIds) { return 0 }
    return @($Item.ProviderIds.PSObject.Properties).Count
}

function Get-EpisodeTypeOptions {
    param([Parameter(Mandatory = $true)]$Library)
    $matches = @($Library.LibraryOptions.TypeOptions | Where-Object { [string]$_.Type -eq "Episode" })
    if ($matches.Count -ne 1) {
        throw ("Expected exactly one Episode TypeOptions entry, got {0}." -f $matches.Count)
    }
    return $matches[0]
}

function Assert-TargetInvariant {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )

    if ([string]$Item.SeriesId -ne $TargetSeriesId) { throw "SeriesId changed during pilot." }
    if ([int]$Item.ParentIndexNumber -ne $ExpectedSeason -or [int]$Item.IndexNumber -ne $ExpectedEpisode) {
        throw ("S/E changed unexpectedly during metadata replacement: {0}/{1}." -f $Item.ParentIndexNumber, $Item.IndexNumber)
    }
    if ([string]$Item.Path -ne $ExpectedPath) { throw "Episode path changed unexpectedly during pilot." }
}

Write-Host ""
Write-Host "=== Medalist S02E01 Metadata Replacement Pilot ==="
Write-Host ("Mode: {0}" -f $(if ($Apply) { "APPLY" } else { "DRY RUN" }))
Write-Host ("Server: {0}" -f $Server)
Write-Host ""

$before = Get-TargetItem
$library = Get-TargetLibrary -Item $before
$episodeOptions = Get-EpisodeTypeOptions -Library $library

if ([string]$before.Id -ne $TargetItemId) { throw "Target ItemId changed." }
if ([string]$before.SeriesId -ne $TargetSeriesId) { throw "Target SeriesId changed." }
if ([int]$before.ParentIndexNumber -ne $ExpectedSeason -or [int]$before.IndexNumber -ne $ExpectedEpisode) {
    throw ("Target is not S{0:D2}E{1:D2}. Current S/E: {2}/{3}." -f $ExpectedSeason, $ExpectedEpisode, $before.ParentIndexNumber, $before.IndexNumber)
}
if ([string]$before.Name -ne $ExpectedName) {
    throw ("Target Name is no longer the expected fallback [{0}]. Current: [{1}]." -f $ExpectedName, [string]$before.Name)
}
if ([string]$before.Path -notmatch '(?i)Medalist - 14 .*\.mkv$') {
    throw ("Unexpected target path: {0}" -f [string]$before.Path)
}
if ((Get-ProviderIdCount -Item $before) -lt 1) {
    throw "Target no longer has ProviderIds; this is not the intended isolated pilot state."
}
if ([string]::IsNullOrWhiteSpace([string]$before.Overview)) {
    throw "Target no longer has an Overview; this is not the intended isolated pilot state."
}

$extension = Get-TvaPathExtension -Path ([string]$before.Path)
if ([string]::IsNullOrWhiteSpace($extension)) { throw "Could not derive target video extension." }
$nfoPath = ([string]$before.Path).Substring(0, ([string]$before.Path).Length - $extension.Length) + ".nfo"
$nfo = Get-TvaNfoSummary -NfoPath $nfoPath

if ([int]$nfo.Season -ne $ExpectedSeason -or [int]$nfo.Episode -ne $ExpectedEpisode) {
    throw ("NFO is not S{0:D2}E{1:D2}. Current NFO S/E: {2}/{3}." -f $ExpectedSeason, $ExpectedEpisode, $nfo.Season, $nfo.Episode)
}
if (-not [string]::IsNullOrWhiteSpace([string]$nfo.Title)) {
    throw ("NFO title is not blank: [{0}]. Refusing isolated title replacement pilot." -f [string]$nfo.Title)
}

if ([bool]$library.LibraryOptions.SaveLocalMetadata) {
    throw "SaveLocalMetadata is enabled. Refusing this pilot because replaceAllMetadata behavior would differ."
}
if (@($library.LibraryOptions.MetadataSavers).Count -ne 0) {
    throw "MetadataSavers is not empty. Refusing this pilot because local metadata saving could change provider behavior."
}
if (@($library.LibraryOptions.LocalMetadataReaderOrder) -notcontains "Nfo") {
    throw "Nfo is not present in LocalMetadataReaderOrder."
}
if (@($library.LibraryOptions.DisabledLocalMetadataReaders) -contains "Nfo") {
    throw "Nfo local metadata reader is disabled."
}
if (@($episodeOptions.MetadataFetchers).Count -lt 1) {
    throw "Episode MetadataFetchers is empty; there is no remote metadata provider to test."
}

if ($before.LockData -eq $true) {
    throw "Target metadata is fully locked (LockData=true)."
}
$lockedFields = @($before.LockedFields | ForEach-Object { [string]$_ })
if ($lockedFields -contains "Name") {
    throw "Target Name is locked in LockedFields."
}

Write-Host "Preflight passed."
Write-Host ("ItemId:             {0}" -f $before.Id)
Write-Host ("Series:             {0}" -f $before.SeriesName)
Write-Host ("Current key:        S{0:D2}E{1:D2}" -f [int]$before.ParentIndexNumber, [int]$before.IndexNumber)
Write-Host ("Current Name:       {0}" -f $before.Name)
Write-Host ("Provider IDs:       {0}" -f (Get-ProviderIdCount -Item $before))
Write-Host ("Overview present:   {0}" -f (-not [string]::IsNullOrWhiteSpace([string]$before.Overview)))
Write-Host ("LockData:           {0}" -f [string]$before.LockData)
Write-Host ("LockedFields:       {0}" -f ($lockedFields -join ","))
Write-Host ("NFO:                {0}" -f $nfoPath)
Write-Host ("NFO key:            S{0:D2}E{1:D2}" -f [int]$nfo.Season, [int]$nfo.Episode)
Write-Host ("NFO title blank:    {0}" -f [string]::IsNullOrWhiteSpace([string]$nfo.Title))
Write-Host ("SaveLocalMetadata:  {0}" -f [bool]$library.LibraryOptions.SaveLocalMetadata)
Write-Host ("MetadataSavers:     {0}" -f @($library.LibraryOptions.MetadataSavers).Count)
Write-Host ("MetadataFetchers:   {0}" -f (@($episodeOptions.MetadataFetchers) -join ", "))
Write-Host ""

if (-not $Apply) {
    Write-Host "DRY RUN COMPLETE: no Jellyfin metadata was changed."
    Write-Host "Run again with -Apply to refresh only this Episode with replaceAllMetadata=true."
    return
}

$beforePath = [string]$before.Path
$refreshUri = "$Server/Items/$TargetItemId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=true&replaceAllImages=false"
Write-Host "Requesting one Episode FullRefresh with replaceAllMetadata=true..."
Invoke-RestMethod -Method Post -Uri $refreshUri -Headers $Headers -ErrorAction Stop | Out-Null
Write-Host "Refresh request accepted."
Write-Host "Jellyfin 12 queues this request asynchronously; BaseItemDto does not expose a reliable completion timestamp/state."
Write-Host ("Observing API-visible item state for up to {0} seconds..." -f $TimeoutSeconds)

$after = $before
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$check = 0
$nameChanged = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $check += 1
    $current = Get-TargetItem
    Assert-TargetInvariant -Item $current -ExpectedPath $beforePath
    Write-Host ("Check {0}: Name=[{1}], ProviderIds={2}, Overview={3}" -f $check, [string]$current.Name, (Get-ProviderIdCount -Item $current), (-not [string]::IsNullOrWhiteSpace([string]$current.Overview)))
    $after = $current

    if ([string]$current.Name -ne [string]$before.Name -and -not [string]::IsNullOrWhiteSpace([string]$current.Name)) {
        $nameChanged = $true
        break
    }
}

Write-Host ""
Write-Host "=== Result ==="
Write-Host ("Before Name:         {0}" -f $before.Name)
Write-Host ("After Name:          {0}" -f $after.Name)
Write-Host ("Before Provider IDs: {0}" -f (Get-ProviderIdCount -Item $before))
Write-Host ("After Provider IDs:  {0}" -f (Get-ProviderIdCount -Item $after))
Write-Host ("Before Overview:     {0}" -f (-not [string]::IsNullOrWhiteSpace([string]$before.Overview)))
Write-Host ("After Overview:      {0}" -f (-not [string]::IsNullOrWhiteSpace([string]$after.Overview)))
Write-Host ("After key:           S{0:D2}E{1:D2}" -f [int]$after.ParentIndexNumber, [int]$after.IndexNumber)

if ($nameChanged) {
    Write-Host "RESULT: NAME_REPLACED"
    Write-Host "The API-visible Name changed during the observation window."
}
else {
    Write-Host "RESULT: NAME_UNCHANGED_AFTER_OBSERVATION"
    Write-Host "No API-visible Name change was observed during the bounded window."
    Write-Host "Important: refresh completion cannot be proven from BaseItemDto in Jellyfin 12."
    Write-Host "Do not interpret this result alone as proof that replaceAllMetadata=true was ignored."
}

Write-Host "No image replacement, media-file change, NFO change, or Series refresh was requested."
