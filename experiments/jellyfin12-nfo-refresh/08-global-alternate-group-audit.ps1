# READ-ONLY EXPERIMENT
# Purpose: audit Jellyfin alternate-version groups that touch NFO correction
# targets and distinguish legitimate multi-version episodes from groups that
# incorrectly combine different expected season/episode numbers.
#
# This script performs GET requests only. It never refreshes, deletes, merges,
# edits, moves, renames, or rewrites media/NFO files or Jellyfin metadata.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Server = "http://127.0.0.1:8096",

    [string]$RunLogPath = ".\jellyfin_tv_nfo_run_log.csv",

    [string]$ResultCsvPath = ".\jellyfin_tv_nfo_alternate_audit.csv",

    [switch]$IncludeExisting
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

$Headers = @{
    Authorization = "MediaBrowser Client=`"alternate-audit`", Device=`"PowerShell`", DeviceId=`"alternate-audit`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JellyfinGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    return Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $Headers `
        -ErrorAction Stop
}

function Get-PathKey {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return $Path.Trim().ToLowerInvariant()
}

function Get-EpisodeKey {
    param(
        $Season,
        $Episode
    )

    if ($null -eq $Season -or $null -eq $Episode) {
        return "UNKNOWN"
    }

    return "S{0:D2}E{1:D2}" -f [int]$Season, [int]$Episode
}

function Get-AllEpisodes {
    param(
        [switch]$IncludeAlternate,
        [switch]$IncludeMediaSources
    )

    $startIndex = 0
    $limit = 500
    $allItems = @()

    do {
        $fields = "Path,MediaSourceCount"
        if ($IncludeMediaSources) {
            $fields = "Path,MediaSources,MediaSourceCount"
        }

        $extraQuery = ""
        if ($IncludeAlternate) {
            $extraQuery = "&VideoTypes=VideoFile"
        }

        $uri = "$Server/Items" +
               "?Recursive=true" +
               "&StartIndex=$startIndex" +
               "&Limit=$limit" +
               "&IncludeItemTypes=Episode" +
               "&Fields=$fields" +
               "&EnableImages=false" +
               "&EnableUserData=false" +
               $extraQuery

        $response = Invoke-JellyfinGet -Uri $uri
        $page = @($response.Items)
        $allItems += $page
        $startIndex += $page.Count

    } while ($page.Count -gt 0 -and $startIndex -lt $response.TotalRecordCount)

    return @($allItems)
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}

$systemInfo = Invoke-JellyfinGet -Uri "$Server/System/Info"

Write-Host ""
Write-Host "=== Jellyfin Alternate Group Audit ==="
Write-Host "Mode: READ ONLY"
Write-Host "Server version: $($systemInfo.Version)"
Write-Host "Run log: $RunLogPath"
Write-Host ""

$rows = @(Import-Csv -LiteralPath $RunLogPath)

$actions = @("WRITE")
if ($IncludeExisting) {
    $actions += "SKIP_EXISTING"
}

$rawTargets = @(
    $rows |
    Where-Object {
        $_.RuleId -ne "series-nfo" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.VideoPath) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Season) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Episode) -and
        $actions -contains [string]$_.Action
    }
)

if ($rawTargets.Count -eq 0) {
    throw "No episode targets found for actions: $($actions -join ', ')"
}

$targets = @()

foreach ($group in ($rawTargets | Group-Object -Property VideoPath)) {
    $seasonValues = @(
        $group.Group |
        ForEach-Object { [int]$_.Season } |
        Sort-Object -Unique
    )

    $episodeValues = @(
        $group.Group |
        ForEach-Object { [int]$_.Episode } |
        Sort-Object -Unique
    )

    if ($seasonValues.Count -ne 1 -or $episodeValues.Count -ne 1) {
        throw "Conflicting targets for video path: $($group.Name)"
    }

    $row = $group.Group[0]

    $targets += [pscustomobject]@{
        Work            = [string]$row.Work
        RuleId          = [string]$row.RuleId
        VideoPath       = [string]$row.VideoPath
        PathKey         = Get-PathKey -Path ([string]$row.VideoPath)
        TargetSeason    = [int]$row.Season
        TargetEpisode   = [int]$row.Episode
        ExpectedKey     = Get-EpisodeKey -Season ([int]$row.Season) -Episode ([int]$row.Episode)
    }
}

$targetByPath = @{}
foreach ($target in $targets) {
    $targetByPath[$target.PathKey] = $target
}

Write-Host "Targets from run log: $($targets.Count)"
Write-Host "Reading normally visible Episodes with MediaSources..."
$normalEpisodes = @(Get-AllEpisodes -IncludeMediaSources)
Write-Host "Normally visible Episodes: $($normalEpisodes.Count)"

Write-Host "Reading Episodes including alternate/owned items..."
$expandedEpisodes = @(Get-AllEpisodes -IncludeAlternate)
Write-Host "Expanded Episodes: $($expandedEpisodes.Count)"

$normalByPath = @{}
$expandedByPath = @{}

foreach ($item in $normalEpisodes) {
    $key = Get-PathKey -Path ([string]$item.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $normalByPath[$key] = $item
    }
}

foreach ($item in $expandedEpisodes) {
    $key = Get-PathKey -Path ([string]$item.Path)
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $expandedByPath[$key] = $item
    }
}

$targetStates = @()

foreach ($target in $targets) {
    $normalItem = $null
    $expandedItem = $null

    if ($normalByPath.ContainsKey($target.PathKey)) {
        $normalItem = $normalByPath[$target.PathKey]
    }

    if ($expandedByPath.ContainsKey($target.PathKey)) {
        $expandedItem = $expandedByPath[$target.PathKey]
    }

    $targetStates += [pscustomobject]@{
        Work            = $target.Work
        VideoPath       = $target.VideoPath
        PathKey         = $target.PathKey
        ExpectedKey     = $target.ExpectedKey
        FoundNormally   = $null -ne $normalItem
        FoundExpanded   = $null -ne $expandedItem
        ItemId          = if ($null -ne $expandedItem) { [string]$expandedItem.Id } else { "" }
        CurrentKey      = if ($null -ne $expandedItem) {
                              Get-EpisodeKey -Season $expandedItem.ParentIndexNumber -Episode $expandedItem.IndexNumber
                          } else {
                              "MISSING"
                          }
        SeriesId        = if ($null -ne $expandedItem) { [string]$expandedItem.SeriesId } else { "" }
        SeasonId        = if ($null -ne $expandedItem) { [string]$expandedItem.SeasonId } else { "" }
    }
}

$ownerGroups = @()
$targetOwnerMap = @{}

foreach ($owner in $normalEpisodes) {
    $sources = @($owner.MediaSources)

    if ($sources.Count -le 1) {
        continue
    }

    $members = @()

    foreach ($source in $sources) {
        $sourcePath = [string]$source.Path
        $sourceKey = Get-PathKey -Path $sourcePath
        $target = $null
        $expanded = $null

        if ($targetByPath.ContainsKey($sourceKey)) {
            $target = $targetByPath[$sourceKey]
        }

        if ($expandedByPath.ContainsKey($sourceKey)) {
            $expanded = $expandedByPath[$sourceKey]
        }

        $members += [pscustomobject]@{
            SourceId        = [string]$source.Id
            SourcePath      = $sourcePath
            IsTarget        = $null -ne $target
            Work            = if ($null -ne $target) { [string]$target.Work } else { "" }
            ExpectedKey     = if ($null -ne $target) { [string]$target.ExpectedKey } else { "" }
            ExpandedItemId  = if ($null -ne $expanded) { [string]$expanded.Id } else { "" }
            CurrentKey      = if ($null -ne $expanded) {
                                  Get-EpisodeKey -Season $expanded.ParentIndexNumber -Episode $expanded.IndexNumber
                              } else {
                                  "UNKNOWN"
                              }
        }
    }

    $targetMembers = @($members | Where-Object { $_.IsTarget })

    if ($targetMembers.Count -eq 0) {
        continue
    }

    $expectedKeys = @(
        $targetMembers |
        ForEach-Object { [string]$_.ExpectedKey } |
        Sort-Object -Unique
    )

    $works = @(
        $targetMembers |
        ForEach-Object { [string]$_.Work } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )

    $unknownMembers = @($members | Where-Object { -not $_.IsTarget }).Count

    $classification = ""

    if ($expectedKeys.Count -gt 1) {
        $classification = "DEFINITELY_WRONG"
    }
    elseif ($expectedKeys.Count -eq 1 -and $unknownMembers -eq 0) {
        $classification = "LEGIT_SAME_EPISODE"
    }
    else {
        $classification = "REVIEW_MIXED_UNKNOWN"
    }

    $group = [pscustomobject]@{
        OwnerItemId         = [string]$owner.Id
        OwnerSeriesId       = [string]$owner.SeriesId
        OwnerSeriesName     = [string]$owner.SeriesName
        OwnerCurrentKey     = Get-EpisodeKey -Season $owner.ParentIndexNumber -Episode $owner.IndexNumber
        OwnerPath           = [string]$owner.Path
        MediaSourceCount    = $sources.Count
        TargetMemberCount   = $targetMembers.Count
        UnknownMemberCount  = $unknownMembers
        ExpectedKeys        = $expectedKeys
        Works               = $works
        Classification      = $classification
        Members             = $members
    }

    $ownerGroups += $group

    foreach ($member in $targetMembers) {
        $memberKey = Get-PathKey -Path ([string]$member.SourcePath)

        if (-not $targetOwnerMap.ContainsKey($memberKey)) {
            $targetOwnerMap[$memberKey] = @()
        }

        $targetOwnerMap[$memberKey] += $group
    }
}

$definitelyWrong = @($ownerGroups | Where-Object { $_.Classification -eq "DEFINITELY_WRONG" })
$legitSameEpisode = @($ownerGroups | Where-Object { $_.Classification -eq "LEGIT_SAME_EPISODE" })
$mixedUnknown = @($ownerGroups | Where-Object { $_.Classification -eq "REVIEW_MIXED_UNKNOWN" })

$hiddenTargets = @($targetStates | Where-Object { -not $_.FoundNormally -and $_.FoundExpanded })
$missingTargets = @($targetStates | Where-Object { -not $_.FoundExpanded })

$hiddenWithoutOwner = @(
    $hiddenTargets |
    Where-Object {
        -not $targetOwnerMap.ContainsKey($_.PathKey) -or
        @($targetOwnerMap[$_.PathKey]).Count -eq 0
    }
)

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ""
Write-Host "Targets:                              $($targets.Count)"
Write-Host "Targets normally visible:             $(@($targetStates | Where-Object { $_.FoundNormally }).Count)"
Write-Host "Targets hidden but expanded-visible:  $($hiddenTargets.Count)"
Write-Host "Targets missing even expanded:        $($missingTargets.Count)"
Write-Host "Alternate groups touching targets:    $($ownerGroups.Count)"
Write-Host "Definitely wrong groups:              $($definitelyWrong.Count)"
Write-Host "Legit same-episode groups:             $($legitSameEpisode.Count)"
Write-Host "Mixed/unknown groups needing review:   $($mixedUnknown.Count)"
Write-Host "Hidden targets without visible owner:  $($hiddenWithoutOwner.Count)"

Write-Host ""
Write-Host "=== Definitely Wrong Groups ==="

if ($definitelyWrong.Count -eq 0) {
    Write-Host "(none)"
}
else {
    foreach ($group in $definitelyWrong) {
        Write-Host ""
        Write-Host "Owner:          $($group.OwnerItemId)"
        Write-Host "Series:         $($group.OwnerSeriesName)"
        Write-Host "SeriesId:       $($group.OwnerSeriesId)"
        Write-Host "Owner current:  $($group.OwnerCurrentKey)"
        Write-Host "Sources:        $($group.MediaSourceCount)"
        Write-Host "Target members: $($group.TargetMemberCount)"
        Write-Host "Expected:       $($group.ExpectedKeys -join ', ')"
        Write-Host "Works:          $($group.Works -join ' | ')"
        Write-Host "Classification: $($group.Classification)"
        Write-Host "Members:"

        $group.Members |
            Select-Object `
                IsTarget,
                Work,
                ExpectedKey,
                CurrentKey,
                SourceId,
                SourcePath |
            Format-Table -AutoSize
    }
}

Write-Host ""
Write-Host "=== Legit Same-Episode Groups ==="

if ($legitSameEpisode.Count -eq 0) {
    Write-Host "(none)"
}
else {
    $legitSameEpisode |
        ForEach-Object {
            [pscustomobject]@{
                OwnerItemId       = $_.OwnerItemId
                Series            = $_.OwnerSeriesName
                OwnerCurrent      = $_.OwnerCurrentKey
                Sources           = $_.MediaSourceCount
                TargetMembers     = $_.TargetMemberCount
                Expected          = ($_.ExpectedKeys -join ', ')
                Works             = ($_.Works -join ' | ')
            }
        } |
        Format-Table -AutoSize
}

Write-Host ""
Write-Host "=== Mixed / Unknown Groups ==="

if ($mixedUnknown.Count -eq 0) {
    Write-Host "(none)"
}
else {
    foreach ($group in $mixedUnknown) {
        Write-Host ""
        Write-Host "Owner:          $($group.OwnerItemId)"
        Write-Host "Series:         $($group.OwnerSeriesName)"
        Write-Host "Owner current:  $($group.OwnerCurrentKey)"
        Write-Host "Sources:        $($group.MediaSourceCount)"
        Write-Host "Target members: $($group.TargetMemberCount)"
        Write-Host "Unknown members:$($group.UnknownMemberCount)"
        Write-Host "Expected:       $($group.ExpectedKeys -join ', ')"
        Write-Host "Works:          $($group.Works -join ' | ')"
        Write-Host "Members:"

        $group.Members |
            Select-Object `
                IsTarget,
                Work,
                ExpectedKey,
                CurrentKey,
                SourceId,
                SourcePath |
            Format-Table -AutoSize
    }
}

$auditRows = @()

foreach ($group in $ownerGroups) {
    foreach ($member in $group.Members) {
        $auditRows += [pscustomobject]@{
            Classification     = $group.Classification
            OwnerItemId        = $group.OwnerItemId
            OwnerSeriesName    = $group.OwnerSeriesName
            OwnerSeriesId      = $group.OwnerSeriesId
            OwnerCurrentKey    = $group.OwnerCurrentKey
            MediaSourceCount   = $group.MediaSourceCount
            TargetMemberCount  = $group.TargetMemberCount
            UnknownMemberCount = $group.UnknownMemberCount
            IsTarget           = $member.IsTarget
            Work               = $member.Work
            ExpectedKey        = $member.ExpectedKey
            CurrentKey         = $member.CurrentKey
            SourceId           = $member.SourceId
            SourcePath         = $member.SourcePath
        }
    }
}

$auditRows |
    Export-Csv `
        -LiteralPath $ResultCsvPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "Audit CSV: $ResultCsvPath"
Write-Host "READ ONLY: nothing was changed."
