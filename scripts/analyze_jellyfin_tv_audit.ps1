[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias("Input")]
    [string]$InputPath,

    [string]$OutputCsv = "",

    [string]$OutputSummary = "",

    [switch]$IncludeTestLibrary
)

$ErrorActionPreference = "Stop"

function Get-AuditPathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Trim().Replace('/', '\').ToLowerInvariant()
}

function Test-AuditHasProviderId {
    param($Item)

    if ($null -eq $Item -or $null -eq $Item.ProviderIds) { return $false }
    return @($Item.ProviderIds.PSObject.Properties).Count -gt 0
}

function Test-AuditHasPrimaryImage {
    param($Item)

    if ($null -eq $Item -or $null -eq $Item.ImageTags) { return $false }
    $property = $Item.ImageTags.PSObject.Properties['Primary']
    return $null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)
}

function Test-AuditExtraLike {
    param(
        [string]$Path,
        [string]$Name
    )

    $candidate = (([string]$Path) + "\" + ([string]$Name)).Replace('/', '\')
    if ($candidate -match '(?i)\\(SPs?|Bonus|Extras?|Tokuten|PV|menu|NCOP&NCED|NCOP|NCED)\\') {
        return $true
    }

    $leaf = ""
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $lastSlash = $Path.LastIndexOf('\')
        if ($lastSlash -ge 0 -and $lastSlash -lt ($Path.Length - 1)) {
            $leaf = $Path.Substring($lastSlash + 1)
        }
        else {
            $leaf = $Path
        }
    }

    $combined = $leaf + " " + ([string]$Name)
    return $combined -match '(?i)(^|[\[\s._-])(NCOP|NCED|OVA|OP|ED|SP)([\]\s._-]|$)'
}

function Add-AuditLabel {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Labels,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Labels.Contains($Label)) {
        $Labels.Add($Label)
    }
}

$inputFull = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $inputFull -PathType Leaf)) {
    throw "Audit JSON not found: $inputFull"
}

$inputDirectory = [System.IO.Path]::GetDirectoryName($inputFull)
$inputBase = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $OutputCsv = Join-Path $inputDirectory ($inputBase + "-ledger.csv")
}
if ([string]::IsNullOrWhiteSpace($OutputSummary)) {
    $OutputSummary = Join-Path $inputDirectory ($inputBase + "-summary.md")
}

$outputCsvFull = [System.IO.Path]::GetFullPath($OutputCsv)
$outputSummaryFull = [System.IO.Path]::GetFullPath($OutputSummary)

Write-Host ""
Write-Host "=== Jellyfin TV Audit Analyzer ==="
Write-Host ("Input: {0}" -f $inputFull)

$jsonText = [System.IO.File]::ReadAllText($inputFull)
$audit = $jsonText | ConvertFrom-Json

if ([int]$audit.SchemaVersion -ne 1) {
    throw ("Unsupported audit schema: {0}" -f [string]$audit.SchemaVersion)
}

$normalItems = @($audit.NormalItems)
$expandedEpisodes = @($audit.ExpandedEpisodes)
$filesystemVideos = @($audit.FilesystemVideos)

if (-not $IncludeTestLibrary) {
    $normalItems = @($normalItems | Where-Object { [string]$_.LibraryName -ne "test" })
    $expandedEpisodes = @($expandedEpisodes | Where-Object { [string]$_.LibraryName -ne "test" })
    $filesystemVideos = @($filesystemVideos | Where-Object { [string]$_.LibraryName -ne "test" })
}

$normalEpisodeIds = @{}
foreach ($item in @($normalItems | Where-Object { [string]$_.Type -eq "Episode" })) {
    $normalEpisodeIds[[string]$item.Id] = $true
}

$filesystemByPath = @{}
foreach ($file in $filesystemVideos) {
    $key = Get-AuditPathKey -Path ([string]$file.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $filesystemByPath[$key] = $file
    }
}

$expandedPathKeys = @{}
foreach ($episode in $expandedEpisodes) {
    $key = Get-AuditPathKey -Path ([string]$episode.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $expandedPathKeys[$key] = $true
    }
}

$titleEpisodeKeys = @{}
foreach ($episode in $expandedEpisodes) {
    $seriesId = [string]$episode.SeriesId
    $title = ([string]$episode.Name).Trim()
    if ([string]::IsNullOrWhiteSpace($seriesId) -or [string]::IsNullOrWhiteSpace($title)) { continue }

    $titleKey = $seriesId + "|" + $title.ToLowerInvariant()
    if (-not $titleEpisodeKeys.ContainsKey($titleKey)) {
        $titleEpisodeKeys[$titleKey] = @{}
    }

    $episodeKey = ([string]$episode.ParentIndexNumber) + "|" + ([string]$episode.IndexNumber)
    $titleEpisodeKeys[$titleKey][$episodeKey] = $true
}

$repeatedTitleKeys = @{}
foreach ($entry in $titleEpisodeKeys.GetEnumerator()) {
    if ($entry.Value.Count -ge 2) {
        $repeatedTitleKeys[$entry.Key] = $true
    }
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($series in @($normalItems | Where-Object { [string]$_.Type -eq "Series" })) {
    $labels = New-Object System.Collections.Generic.List[string]

    if (-not (Test-AuditHasProviderId -Item $series)) {
        Add-AuditLabel -Labels $labels -Label "SERIES_METADATA_MISSING_PROVIDER_ID"
    }
    if ([string]::IsNullOrWhiteSpace([string]$series.Overview)) {
        Add-AuditLabel -Labels $labels -Label "SERIES_METADATA_MISSING_OVERVIEW"
    }
    if (-not (Test-AuditHasPrimaryImage -Item $series)) {
        Add-AuditLabel -Labels $labels -Label "SERIES_METADATA_MISSING_PRIMARY_IMAGE"
    }

    $rows.Add([pscustomobject]@{
        ItemType            = "Series"
        LibraryName         = [string]$series.LibraryName
        SeriesName          = [string]$series.Name
        SeriesId            = [string]$series.Id
        ItemId              = [string]$series.Id
        Season              = ""
        Episode             = ""
        Title               = [string]$series.Name
        Path                = [string]$series.Path
        VisibleInNormalView = $true
        CorrectionTargetNfo = $false
        NfoSeason           = ""
        NfoEpisode          = ""
        NfoStructureMatches = ""
        HasProviderId       = (Test-AuditHasProviderId -Item $series)
        HasOverview         = (-not [string]::IsNullOrWhiteSpace([string]$series.Overview))
        HasPrimaryImage     = (Test-AuditHasPrimaryImage -Item $series)
        MediaSourceCount    = ""
        ScopeTags           = "SERIES"
        IssueLabels         = ($labels -join ";")
    })
}

foreach ($episode in $expandedEpisodes) {
    $labels = New-Object System.Collections.Generic.List[string]
    $scope = New-Object System.Collections.Generic.List[string]

    $path = [string]$episode.Path
    $pathKey = Get-AuditPathKey -Path $path
    $file = $null
    if ($filesystemByPath.ContainsKey($pathKey)) {
        $file = $filesystemByPath[$pathKey]
    }

    $visible = $normalEpisodeIds.ContainsKey([string]$episode.Id)
    $hasNfo = $false
    $nfoSeason = ""
    $nfoEpisode = ""
    $nfoMatches = ""

    if ($null -ne $file -and [bool]$file.SameNameNfoExists) {
        $hasNfo = $true
        Add-AuditLabel -Labels $scope -Label "CORRECTION_TARGET_NFO"

        if ($null -ne $file.NfoSummary) {
            $nfoSeason = [string]$file.NfoSummary.Season
            $nfoEpisode = [string]$file.NfoSummary.Episode
            $nfoMatches = ([string]$episode.ParentIndexNumber -eq $nfoSeason -and [string]$episode.IndexNumber -eq $nfoEpisode)
            if (-not $nfoMatches) {
                Add-AuditLabel -Labels $labels -Label "STRUCTURE_NFO_MISMATCH"
            }
        }
    }

    if (-not $visible) {
        Add-AuditLabel -Labels $labels -Label "STRUCTURE_HIDDEN_ALTERNATE"
        if (-not $hasNfo) {
            Add-AuditLabel -Labels $labels -Label "REVIEW_NON_TARGET_HIDDEN"
        }
    }

    $title = ([string]$episode.Name).Trim()
    $repeatKey = [string]$episode.SeriesId + "|" + $title.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($title) -and $repeatedTitleKeys.ContainsKey($repeatKey)) {
        Add-AuditLabel -Labels $labels -Label "METADATA_REPEATED_TITLE_ACROSS_EPISODES"
    }

    if (-not (Test-AuditHasProviderId -Item $episode)) {
        Add-AuditLabel -Labels $labels -Label "METADATA_MISSING_PROVIDER_ID"
    }
    if ([string]::IsNullOrWhiteSpace([string]$episode.Overview)) {
        Add-AuditLabel -Labels $labels -Label "METADATA_MISSING_OVERVIEW"
    }
    if (-not (Test-AuditHasPrimaryImage -Item $episode)) {
        Add-AuditLabel -Labels $labels -Label "METADATA_MISSING_PRIMARY_IMAGE"
    }

    if (Test-AuditExtraLike -Path $path -Name $title) {
        Add-AuditLabel -Labels $labels -Label "REVIEW_EXTRAS"
    }

    $rows.Add([pscustomobject]@{
        ItemType            = "Episode"
        LibraryName         = [string]$episode.LibraryName
        SeriesName          = [string]$episode.SeriesName
        SeriesId            = [string]$episode.SeriesId
        ItemId              = [string]$episode.Id
        Season              = [string]$episode.ParentIndexNumber
        Episode             = [string]$episode.IndexNumber
        Title               = [string]$episode.Name
        Path                = $path
        VisibleInNormalView = $visible
        CorrectionTargetNfo = $hasNfo
        NfoSeason           = $nfoSeason
        NfoEpisode          = $nfoEpisode
        NfoStructureMatches = $nfoMatches
        HasProviderId       = (Test-AuditHasProviderId -Item $episode)
        HasOverview         = (-not [string]::IsNullOrWhiteSpace([string]$episode.Overview))
        HasPrimaryImage     = (Test-AuditHasPrimaryImage -Item $episode)
        MediaSourceCount    = [string]$episode.MediaSourceCount
        ScopeTags           = ($scope -join ";")
        IssueLabels         = ($labels -join ";")
    })
}

foreach ($file in $filesystemVideos) {
    $pathKey = Get-AuditPathKey -Path ([string]$file.Path)
    if ($expandedPathKeys.ContainsKey($pathKey)) { continue }

    $labels = New-Object System.Collections.Generic.List[string]
    Add-AuditLabel -Labels $labels -Label "FILESYSTEM_NOT_IN_JELLYFIN"
    if (Test-AuditExtraLike -Path ([string]$file.Path) -Name "") {
        Add-AuditLabel -Labels $labels -Label "REVIEW_EXTRAS"
    }

    $rows.Add([pscustomobject]@{
        ItemType            = "FilesystemVideo"
        LibraryName         = [string]$file.LibraryName
        SeriesName          = ""
        SeriesId            = ""
        ItemId              = ""
        Season              = ""
        Episode             = ""
        Title               = ""
        Path                = [string]$file.Path
        VisibleInNormalView = $false
        CorrectionTargetNfo = [bool]$file.SameNameNfoExists
        NfoSeason           = if ($null -ne $file.NfoSummary) { [string]$file.NfoSummary.Season } else { "" }
        NfoEpisode          = if ($null -ne $file.NfoSummary) { [string]$file.NfoSummary.Episode } else { "" }
        NfoStructureMatches = ""
        HasProviderId       = $false
        HasOverview         = $false
        HasPrimaryImage     = $false
        MediaSourceCount    = ""
        ScopeTags           = "FILESYSTEM_ONLY"
        IssueLabels         = ($labels -join ";")
    })
}

foreach ($outputPath in @($outputCsvFull, $outputSummaryFull)) {
    $directory = [System.IO.Path]::GetDirectoryName($outputPath)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$rows | Sort-Object LibraryName, SeriesName, ItemType, Season, Episode, Path | Export-Csv -LiteralPath $outputCsvFull -NoTypeInformation -Encoding UTF8

$issueCounts = @{}
foreach ($row in $rows) {
    foreach ($label in @(([string]$row.IssueLabels).Split(';'))) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if (-not $issueCounts.ContainsKey($label)) { $issueCounts[$label] = 0 }
        $issueCounts[$label] += 1
    }
}

$episodeRows = @($rows | Where-Object { $_.ItemType -eq "Episode" })
$seriesRows = @($rows | Where-Object { $_.ItemType -eq "Series" })
$correctionRows = @($episodeRows | Where-Object { $_.CorrectionTargetNfo })
$hiddenRows = @($episodeRows | Where-Object { -not $_.VisibleInNormalView })
$hiddenCorrectionRows = @($correctionRows | Where-Object { -not $_.VisibleInNormalView })
$nonTargetHiddenRows = @($hiddenRows | Where-Object { -not $_.CorrectionTargetNfo })
$filesystemOnlyRows = @($rows | Where-Object { $_.ItemType -eq "FilesystemVideo" })

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("# Jellyfin TV audit summary")
$summaryLines.Add("")
$summaryLines.Add(("Source export: {0}" -f $inputFull))
$summaryLines.Add(("Generated: {0}" -f (Get-Date).ToString("o")))
$summaryLines.Add("")
$summaryLines.Add("## Coverage")
$summaryLines.Add("")
$summaryLines.Add(("- Series rows: {0}" -f $seriesRows.Count))
$summaryLines.Add(("- Expanded Episode rows: {0}" -f $episodeRows.Count))
$summaryLines.Add(("- Correction-target NFO rows: {0}" -f $correctionRows.Count))
$summaryLines.Add(("- Hidden Episode rows: {0}" -f $hiddenRows.Count))
$summaryLines.Add(("- Hidden correction-target rows: {0}" -f $hiddenCorrectionRows.Count))
$summaryLines.Add(("- Hidden non-target rows: {0}" -f $nonTargetHiddenRows.Count))
$summaryLines.Add(("- Filesystem-only rows: {0}" -f $filesystemOnlyRows.Count))
$summaryLines.Add("")
$summaryLines.Add("## Issue labels")
$summaryLines.Add("")
foreach ($label in @($issueCounts.Keys | Sort-Object)) {
    $summaryLines.Add(("- {0}: {1}" -f $label, $issueCounts[$label]))
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($outputSummaryFull, $summaryLines, $utf8NoBom)

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ("Series rows:                 {0}" -f $seriesRows.Count)
Write-Host ("Expanded Episode rows:       {0}" -f $episodeRows.Count)
Write-Host ("Correction-target NFO rows:  {0}" -f $correctionRows.Count)
Write-Host ("Hidden Episode rows:         {0}" -f $hiddenRows.Count)
Write-Host ("Hidden correction targets:   {0}" -f $hiddenCorrectionRows.Count)
Write-Host ("Hidden non-target rows:      {0}" -f $nonTargetHiddenRows.Count)
Write-Host ("Filesystem-only rows:        {0}" -f $filesystemOnlyRows.Count)
Write-Host ("Ledger:                      {0}" -f $outputCsvFull)
Write-Host ("Summary:                     {0}" -f $outputSummaryFull)