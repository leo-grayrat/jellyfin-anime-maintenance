# MEDALIST S02E01 LOOKUP INPUT READ-ONLY DIAGNOSTIC
#
# Purpose: inspect the values Jellyfin can use to build EpisodeInfo for remote
# metadata providers after the first replaceAllMetadata=true pilot.
#
# This script performs GET requests only.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096"
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

$TargetItemId = "6993f67864a11e1151e7c9c6d3eee68d"
$TargetSeriesId = "1e343af25a95b525ae23adc50142693a"
$ExpectedSeason = 2
$ExpectedEpisode = 1

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot "scripts\lib\tv_audit_common.ps1")

$Headers = @{
    Authorization = "MediaBrowser Client=`"medalist-lookup-input-diagnostic`", Device=`"PowerShell`", DeviceId=`"medalist-lookup-input-diagnostic`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JfGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-OneItem {
    param(
        [Parameter(Mandatory = $true)][string]$ItemId,
        [Parameter(Mandatory = $true)][string]$ItemType
    )

    $fields = [uri]::EscapeDataString("Path,ProviderIds,Overview,Settings,OriginalTitle,SortName,MediaSourceCount")
    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=$ItemType&Recursive=true&Limit=1&Fields=$fields&EnableImages=false&EnableUserData=false"
    $response = Invoke-JfGet -Uri $uri
    $items = @($response.Items)
    if ($items.Count -ne 1) {
        throw ("Expected exactly one {0} for id {1}, got {2}." -f $ItemType, $ItemId, $items.Count)
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

function Get-EpisodeTypeOptions {
    param([Parameter(Mandatory = $true)]$Library)
    $matches = @($Library.LibraryOptions.TypeOptions | Where-Object { [string]$_.Type -eq "Episode" })
    if ($matches.Count -ne 1) {
        throw ("Expected exactly one Episode TypeOptions entry, got {0}." -f $matches.Count)
    }
    return $matches[0]
}

function Write-ProviderIds {
    param(
        $Item,
        [Parameter(Mandatory = $true)][string]$Indent
    )

    $properties = @()
    if ($null -ne $Item.ProviderIds) {
        $properties = @($Item.ProviderIds.PSObject.Properties | Sort-Object Name)
    }

    if ($properties.Count -eq 0) {
        Write-Host ("{0}(none)" -f $Indent)
        return
    }

    foreach ($property in $properties) {
        Write-Host ("{0}{1} = {2}" -f $Indent, $property.Name, [string]$property.Value)
    }
}

function Write-Value {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        $Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = "(blank)"
    }
    Write-Host ("{0,-28}{1}" -f ($Label + ":"), $text)
}

Write-Host ""
Write-Host "=== Medalist S02E01 Lookup Input Diagnostic ==="
Write-Host "Mode: READ ONLY"
Write-Host ("Server: {0}" -f $Server)
Write-Host ""

$episode = Get-OneItem -ItemId $TargetItemId -ItemType "Episode"
if ([string]$episode.Id -ne $TargetItemId) { throw "Target ItemId changed." }
if ([string]$episode.SeriesId -ne $TargetSeriesId) { throw "Target SeriesId changed." }
if ([int]$episode.ParentIndexNumber -ne $ExpectedSeason -or [int]$episode.IndexNumber -ne $ExpectedEpisode) {
    throw ("Target key changed unexpectedly. Current S/E: {0}/{1}." -f $episode.ParentIndexNumber, $episode.IndexNumber)
}

$series = Get-OneItem -ItemId $TargetSeriesId -ItemType "Series"
$season = $null
if (-not [string]::IsNullOrWhiteSpace([string]$episode.SeasonId) -and [string]$episode.SeasonId -ne "00000000000000000000000000000000") {
    $season = Get-OneItem -ItemId ([string]$episode.SeasonId) -ItemType "Season"
}

$library = Get-TargetLibrary -Item $episode
$episodeOptions = Get-EpisodeTypeOptions -Library $library

Write-Host "--- Episode relationship / item settings ---"
Write-Value -Label "ItemId" -Value $episode.Id
Write-Value -Label "SeriesId" -Value $episode.SeriesId
Write-Value -Label "SeasonId" -Value $episode.SeasonId
Write-Value -Label "Key" -Value ("S{0:D2}E{1:D2}" -f [int]$episode.ParentIndexNumber, [int]$episode.IndexNumber)
Write-Value -Label "Name" -Value $episode.Name
Write-Value -Label "Overview present" -Value (-not [string]::IsNullOrWhiteSpace([string]$episode.Overview))
Write-Value -Label "PreferredMetadataLanguage" -Value $episode.PreferredMetadataLanguage
Write-Value -Label "PreferredMetadataCountryCode" -Value $episode.PreferredMetadataCountryCode
Write-Host "Episode ProviderIds:"
Write-ProviderIds -Item $episode -Indent "  "
Write-Host ""

Write-Host "--- Series lookup source ---"
Write-Value -Label "SeriesId" -Value $series.Id
Write-Value -Label "Name" -Value $series.Name
Write-Value -Label "OriginalTitle" -Value $series.OriginalTitle
Write-Value -Label "DisplayOrder" -Value $series.DisplayOrder
Write-Value -Label "PreferredMetadataLanguage" -Value $series.PreferredMetadataLanguage
Write-Value -Label "PreferredMetadataCountryCode" -Value $series.PreferredMetadataCountryCode
Write-Host "Series ProviderIds:"
Write-ProviderIds -Item $series -Indent "  "
Write-Host ""

Write-Host "--- Season relationship ---"
if ($null -eq $season) {
    Write-Host "Season object:               (not resolved from Episode SeasonId)"
}
else {
    Write-Value -Label "Season object Id" -Value $season.Id
    Write-Value -Label "Season Name" -Value $season.Name
    Write-Value -Label "Season IndexNumber" -Value $season.IndexNumber
    Write-Host "Season ProviderIds:"
    Write-ProviderIds -Item $season -Indent "  "
}
Write-Host ""

Write-Host "--- TV library metadata settings ---"
Write-Value -Label "Library Name" -Value $library.Name
Write-Value -Label "PreferredMetadataLanguage" -Value $library.LibraryOptions.PreferredMetadataLanguage
Write-Value -Label "MetadataCountryCode" -Value $library.LibraryOptions.MetadataCountryCode
Write-Value -Label "Episode MetadataFetchers" -Value (@($episodeOptions.MetadataFetchers) -join ", ")
Write-Value -Label "Episode MetadataFetcherOrder" -Value (@($episodeOptions.MetadataFetcherOrder) -join ", ")
Write-Value -Label "SaveLocalMetadata" -Value $library.LibraryOptions.SaveLocalMetadata
Write-Value -Label "MetadataSavers count" -Value @($library.LibraryOptions.MetadataSavers).Count
Write-Host ""

Write-Host "Interpretation notes:"
Write-Host "- Jellyfin Episode.GetLookupInfo copies Series.ProviderIds and Series.DisplayOrder when the Series object resolves."
Write-Host "- TheMovieDb Episode lookup uses Series Tmdb id + S/E and may remap through DisplayOrder episode groups."
Write-Host "- OMDb Episode lookup uses Series IMDb id + S/E."
Write-Host ""
Write-Host "No POST/PUT/PATCH/DELETE request was sent and no local file was changed."
