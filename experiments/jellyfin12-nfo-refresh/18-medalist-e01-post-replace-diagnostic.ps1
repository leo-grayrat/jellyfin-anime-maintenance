# MEDALIST S02E01 POST-REPLACE READ-ONLY DIAGNOSTIC
#
# Purpose: inspect the state left by the first replaceAllMetadata=true pilot and
# collect relevant Jellyfin server log context without changing metadata.
#
# This script performs GET requests only.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [int]$MaxLogs = 3,
    [int]$ContextLines = 4
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

if ($MaxLogs -lt 1) { throw "MaxLogs must be at least 1." }
if ($ContextLines -lt 0) { throw "ContextLines must be non-negative." }

$TargetItemId = "6993f67864a11e1151e7c9c6d3eee68d"
$TargetSeriesId = "1e343af25a95b525ae23adc50142693a"
$ExpectedSeason = 2
$ExpectedEpisode = 1
$TargetPathMarker = "Medalist - 14"

$Headers = @{
    Authorization = "MediaBrowser Client=`"medalist-post-replace-diagnostic`", Device=`"PowerShell`", DeviceId=`"medalist-post-replace-diagnostic`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JfGetJson {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Invoke-JfGetText {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
    return [string]$response.Content
}

function Get-OneItem {
    param(
        [Parameter(Mandatory = $true)][string]$ItemId,
        [Parameter(Mandatory = $true)][string]$ItemType
    )

    $fields = [uri]::EscapeDataString("Path,ProviderIds,Overview,Settings,OriginalTitle,SortName,MediaSourceCount")
    $uri = "$Server/Items?Ids=$ItemId&IncludeItemTypes=$ItemType&Recursive=true&Limit=1&Fields=$fields&EnableImages=true&ImageTypeLimit=1&EnableUserData=false"
    $response = Invoke-JfGetJson -Uri $uri
    $items = @($response.Items)
    if ($items.Count -ne 1) {
        throw ("Expected exactly one {0} for id {1}, got {2}." -f $ItemType, $ItemId, $items.Count)
    }
    return $items[0]
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

function Get-RelevantLogContext {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Markers,
        [Parameter(Mandatory = $true)][int]$Radius
    )

    $lines = @($Text -split "`r?`n")
    $selected = @{}

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $matched = $false
        foreach ($marker in $Markers) {
            if ($lines[$i].IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matched = $true
                break
            }
        }

        if (-not $matched) { continue }

        $start = [Math]::Max(0, $i - $Radius)
        $end = [Math]::Min($lines.Count - 1, $i + $Radius)
        for ($j = $start; $j -le $end; $j++) {
            $selected[$j] = $true
        }
    }

    if ($selected.Count -eq 0) {
        return @()
    }

    $result = @()
    $last = -2
    foreach ($index in @($selected.Keys | ForEach-Object { [int]$_ } | Sort-Object)) {
        if ($last -ge 0 -and $index -gt ($last + 1)) {
            $result += "..."
        }
        $result += ("{0:D6}: {1}" -f ($index + 1), $lines[$index])
        $last = $index
    }
    return $result
}

Write-Host ""
Write-Host "=== Medalist S02E01 Post-Replace Diagnostic ==="
Write-Host "Mode: READ ONLY"
Write-Host ("Server: {0}" -f $Server)
Write-Host ""

$item = Get-OneItem -ItemId $TargetItemId -ItemType "Episode"
$series = Get-OneItem -ItemId $TargetSeriesId -ItemType "Series"

if ([string]$item.Id -ne $TargetItemId) { throw "Target ItemId changed." }
if ([string]$item.SeriesId -ne $TargetSeriesId) { throw "Target SeriesId changed." }
if ([int]$item.ParentIndexNumber -ne $ExpectedSeason -or [int]$item.IndexNumber -ne $ExpectedEpisode) {
    throw ("Target key changed unexpectedly. Current S/E: {0}/{1}." -f $item.ParentIndexNumber, $item.IndexNumber)
}
if ([string]$item.Path -notmatch '(?i)Medalist - 14 .*\.mkv$') {
    throw ("Unexpected target path: {0}" -f [string]$item.Path)
}

Write-Host "--- Episode current state ---"
Write-Host ("ItemId:            {0}" -f $item.Id)
Write-Host ("Series:            {0}" -f $item.SeriesName)
Write-Host ("Key:               S{0:D2}E{1:D2}" -f [int]$item.ParentIndexNumber, [int]$item.IndexNumber)
Write-Host ("Name:              [{0}]" -f [string]$item.Name)
Write-Host ("OriginalTitle:     [{0}]" -f [string]$item.OriginalTitle)
Write-Host ("Overview present:  {0}" -f (-not [string]::IsNullOrWhiteSpace([string]$item.Overview)))
Write-Host ("Path:              {0}" -f [string]$item.Path)
Write-Host "ProviderIds:"
Write-ProviderIds -Item $item -Indent "  "
Write-Host ""

Write-Host "--- Series current state ---"
Write-Host ("SeriesId:          {0}" -f $series.Id)
Write-Host ("Name:              [{0}]" -f [string]$series.Name)
Write-Host ("OriginalTitle:     [{0}]" -f [string]$series.OriginalTitle)
Write-Host ("Overview present:  {0}" -f (-not [string]::IsNullOrWhiteSpace([string]$series.Overview)))
Write-Host "ProviderIds:"
Write-ProviderIds -Item $series -Indent "  "
Write-Host ""

Write-Host "--- Recent Jellyfin log context ---"
$logs = Invoke-JfGetJson -Uri "$Server/System/Logs"
$selectedLogs = @()

# Jellyfin already returns /System/Logs ordered by DateModified descending.
# Enumerate explicitly instead of piping the Invoke-RestMethod array through
# Sort-Object; Windows PowerShell 5.1 may otherwise expose the JSON array as a
# single Object[] and make $_.DateModified an Object[].
foreach ($candidateLog in $logs) {
    $selectedLogs += $candidateLog
    if ($selectedLogs.Count -ge $MaxLogs) {
        break
    }
}

if ($selectedLogs.Count -eq 0) {
    Write-Host "No server log files were returned by /System/Logs."
    return
}

$markers = @(
    $TargetItemId,
    $TargetPathMarker
)

$foundAny = $false
foreach ($log in $selectedLogs) {
    $name = [string]$log.Name
    $encodedName = [uri]::EscapeDataString($name)
    Write-Host ("Log: {0}  Modified: {1}" -f $name, [string]$log.DateModified)

    $text = Invoke-JfGetText -Uri "$Server/System/Logs/Log?name=$encodedName"
    $context = @(Get-RelevantLogContext -Text $text -Markers $markers -Radius $ContextLines)
    if ($context.Count -eq 0) {
        Write-Host "  No lines matched the target ItemId or Medalist - 14 path marker."
        Write-Host "  Note: normal provider success/no-metadata messages are Debug-level and may be absent from default logs."
    }
    else {
        $foundAny = $true
        foreach ($line in $context) {
            Write-Host $line
        }
    }
    Write-Host ""
}

if (-not $foundAny) {
    Write-Host "RESULT: NO_TARGET_LOG_LINES"
    Write-Host "The current logs do not expose the target refresh at their configured log level."
}
else {
    Write-Host "RESULT: TARGET_LOG_LINES_FOUND"
    Write-Host "Inspect the context for provider errors or no-metadata behavior around the target path."
}

Write-Host "No POST/PUT/PATCH/DELETE request was sent and no local file was changed."
