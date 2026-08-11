param(
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [string]$RunLogPath = (Join-Path $PSScriptRoot "..\jellyfin_tv_nfo_run_log.csv"),
    [string]$ResultLogPath = (Join-Path $PSScriptRoot "..\jellyfin_tv_nfo_refresh_log.csv"),
    [switch]$Apply,
    [switch]$IncludeExisting,
    [switch]$ReplaceAllMetadata,
    [int]$EpisodeTimeoutSeconds = 600,
    [int]$SeriesTimeoutSeconds = 300,
    [int]$PollIntervalSeconds = 5,
    [int]$QueueDelayMilliseconds = 100
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')

$Headers = @{
    Authorization = "MediaBrowser Client=`"nfo-refresh`", Device=`"PowerShell`", DeviceId=`"nfo-refresh`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JellyfinGet {
    param([Parameter(Mandatory=$true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
}

function Invoke-JellyfinFullRefresh {
    param([Parameter(Mandatory=$true)][string]$ItemId)

    $replace = "false"
    if ($ReplaceAllMetadata) {
        $replace = "true"
    }

    $uri = "$Server/Items/$ItemId/Refresh" +
           "?metadataRefreshMode=FullRefresh" +
           "&imageRefreshMode=None" +
           "&replaceAllMetadata=$replace" +
           "&replaceAllImages=false"

    Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers | Out-Null
}

function Get-AllItemsByType {
    param([Parameter(Mandatory=$true)][string]$ItemType)

    $startIndex = 0
    $limit = 500
    $allItems = @()

    # Jellyfin groups files that were previously parsed as the same episode.
    # Supplying VideoTypes for Episode queries makes Jellyfin include owned /
    # alternate linked video items as well, so every physical path can be found.
    $extraQuery = ""
    if ($ItemType -eq "Episode") {
        $extraQuery = "&VideoTypes=VideoFile"
    }

    do {
        $uri = "$Server/Items" +
               "?Recursive=true" +
               "&StartIndex=$startIndex" +
               "&Limit=$limit" +
               "&IncludeItemTypes=$ItemType" +
               "&Fields=Path,ParentId" +
               "&EnableImages=false" +
               "&EnableUserData=false" +
               $extraQuery

        $response = Invoke-JellyfinGet -Uri $uri
        $items = @($response.Items)
        $allItems += $items
        $startIndex += $items.Count
    } while ($items.Count -gt 0 -and $startIndex -lt $response.TotalRecordCount)

    return $allItems
}

function New-PathMap {
    param([Parameter(Mandatory=$true)]$Items)

    $map = @{}
    foreach ($item in $Items) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Path)) {
            $map[[string]$item.Path] = $item
        }
    }
    return $map
}

function New-SeasonMap {
    param([Parameter(Mandatory=$true)]$Seasons)

    $map = @{}
    foreach ($season in $Seasons) {
        if ($null -eq $season.IndexNumber) {
            continue
        }

        $ownerId = [string]$season.SeriesId
        if ([string]::IsNullOrWhiteSpace($ownerId)) {
            $ownerId = [string]$season.ParentId
        }
        if ([string]::IsNullOrWhiteSpace($ownerId)) {
            continue
        }

        $key = $ownerId + "|" + [string]([int]$season.IndexNumber)
        $map[$key] = $season
    }
    return $map
}

function Test-TargetNumbers {
    param($Item, [int]$Season, [int]$Episode)

    if ($null -eq $Item) {
        return $false
    }
    if ($null -eq $Item.ParentIndexNumber -or $null -eq $Item.IndexNumber) {
        return $false
    }

    return ([int]$Item.ParentIndexNumber -eq $Season -and
            [int]$Item.IndexNumber -eq $Episode)
}

if (-not (Test-Path -LiteralPath $RunLogPath -PathType Leaf)) {
    throw "Run log not found: $RunLogPath"
}
if ($PollIntervalSeconds -lt 1) {
    throw "PollIntervalSeconds must be at least 1."
}

Write-Host ""
Write-Host "Jellyfin 12 NFO Metadata Refresher"
if ($Apply) {
    Write-Host "Mode: APPLY (Jellyfin metadata will be refreshed)" -ForegroundColor Yellow
} else {
    Write-Host "Mode: DRY RUN (no Jellyfin metadata will be changed)" -ForegroundColor Cyan
}
Write-Host "Run log: $RunLogPath"
Write-Host ""

try {
    $systemInfo = Invoke-JellyfinGet -Uri "$Server/System/Info"
    Write-Host "Server version: $($systemInfo.Version)"
    if (-not ([string]$systemInfo.Version).StartsWith("12.")) {
        Write-Warning "This workflow was designed for Jellyfin 12.x."
    }
} catch {
    throw "Cannot connect to Jellyfin with the supplied API key. $($_.Exception.Message)"
}

$rows = @(Import-Csv -LiteralPath $RunLogPath)
if ($rows.Count -eq 0) {
    throw "Run log is empty."
}

$actions = @("WRITE")
if ($IncludeExisting) {
    $actions += "SKIP_EXISTING"
}

$rawTargets = @($rows | Where-Object {
    $_.RuleId -ne "series-nfo" -and
    -not [string]::IsNullOrWhiteSpace([string]$_.VideoPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.NfoPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.Season) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.Episode) -and
    $actions -contains [string]$_.Action
})

if ($rawTargets.Count -eq 0) {
    Write-Host "No episode targets found for actions: $($actions -join ', ')"
    Write-Host "Use -IncludeExisting to also process SKIP_EXISTING rows."
    return
}

$targets = New-Object System.Collections.Generic.List[object]
foreach ($group in ($rawTargets | Group-Object -Property VideoPath)) {
    $seasonValues = @($group.Group | ForEach-Object { [int]$_.Season } | Select-Object -Unique)
    $episodeValues = @($group.Group | ForEach-Object { [int]$_.Episode } | Select-Object -Unique)

    if ($seasonValues.Count -ne 1 -or $episodeValues.Count -ne 1) {
        throw "Conflicting targets for video path: $($group.Name)"
    }

    $row = $group.Group[0]
    $targets.Add([pscustomobject]@{
        RuleId = [string]$row.RuleId
        Work = [string]$row.Work
        VideoPath = [string]$row.VideoPath
        NfoPath = [string]$row.NfoPath
        TargetSeason = [int]$row.Season
        TargetEpisode = [int]$row.Episode
    })
}

Write-Host "Targets from run log: $($targets.Count)"
Write-Host "Reading current Jellyfin episodes (including alternate versions)..."

$episodes = @(Get-AllItemsByType -ItemType "Episode")
$episodeByPath = New-PathMap -Items $episodes

Write-Host "Episode items returned by Jellyfin: $($episodes.Count)"

$states = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
    $item = $null
    if ($episodeByPath.ContainsKey($target.VideoPath)) {
        $item = $episodeByPath[$target.VideoPath]
    }

    $nfoExists = Test-Path -LiteralPath $target.NfoPath -PathType Leaf
    $itemFound = $null -ne $item

    $itemId = ""
    $seriesId = ""
    $beforeSeason = $null
    $beforeEpisode = $null
    $beforeSeasonId = ""

    if ($itemFound) {
        $itemId = [string]$item.Id
        $seriesId = [string]$item.SeriesId
        $beforeSeason = $item.ParentIndexNumber
        $beforeEpisode = $item.IndexNumber
        $beforeSeasonId = [string]$item.SeasonId
    }

    $state = [pscustomobject]@{
        RuleId = $target.RuleId
        Work = $target.Work
        VideoPath = $target.VideoPath
        NfoPath = $target.NfoPath
        TargetSeason = $target.TargetSeason
        TargetEpisode = $target.TargetEpisode
        NfoExists = $nfoExists
        ItemFound = $itemFound
        ItemId = $itemId
        SeriesId = $seriesId
        BeforeSeason = $beforeSeason
        BeforeEpisode = $beforeEpisode
        BeforeSeasonId = $beforeSeasonId
        EpisodeRefresh = ""
        SeriesRefresh = ""
        AfterSeason = $null
        AfterEpisode = $null
        AfterSeasonId = ""
        ExpectedSeasonId = ""
        Result = ""
        Message = ""
    }

    if (-not $nfoExists) {
        $state.Result = "NFO_MISSING"
        $state.Message = "NFO sidecar does not exist"
    } elseif (-not $itemFound) {
        $state.Result = "ITEM_NOT_FOUND"
        $state.Message = "Video path was not found in Jellyfin, including alternate versions"
    } elseif (Test-TargetNumbers -Item $item -Season $target.TargetSeason -Episode $target.TargetEpisode) {
        $state.EpisodeRefresh = "NOT_NEEDED"
    } else {
        $state.EpisodeRefresh = "NEEDED"
    }

    $states.Add($state)
}

$missingNfo = @($states | Where-Object { -not $_.NfoExists }).Count
$missingItems = @($states | Where-Object { $_.NfoExists -and -not $_.ItemFound }).Count
$needsEpisodeRefresh = @($states | Where-Object { $_.EpisodeRefresh -eq "NEEDED" }).Count
$numbersAlreadyCorrect = @($states | Where-Object { $_.EpisodeRefresh -eq "NOT_NEEDED" }).Count

Write-Host "NFO missing: $missingNfo"
Write-Host "Jellyfin item missing: $missingItems"
Write-Host "Episode numbers need refresh: $needsEpisodeRefresh"
Write-Host "Episode numbers already correct: $numbersAlreadyCorrect"
Write-Host ""

if (-not $Apply) {
    foreach ($state in $states) {
        if ([string]::IsNullOrWhiteSpace($state.Result)) {
            if ($state.EpisodeRefresh -eq "NEEDED") {
                $state.Result = "DRY_RUN_NEEDS_EPISODE_REFRESH"
                $state.Message = "Would FullRefresh this episode and then its series"
            } else {
                $state.Result = "DRY_RUN_SERIES_CHECK"
                $state.Message = "Episode numbers are correct; would refresh its series for season relinking"
            }
        }
    }

    $states | Export-Csv -LiteralPath $ResultLogPath -NoTypeInformation -Encoding UTF8

    Write-Host "Dry run finished."
    Write-Host "Result log: $ResultLogPath"
    Write-Host "To apply:"
    Write-Host "  .\scripts\refresh_jellyfin_nfo_12.ps1 -ApiKey <API_KEY> -Apply"
    if (-not $IncludeExisting) {
        Write-Host "Add -IncludeExisting only when old SKIP_EXISTING rows also need to be reprocessed."
    }
    return
}

$episodeRefreshStates = @($states | Where-Object { $_.EpisodeRefresh -eq "NEEDED" })

if ($episodeRefreshStates.Count -gt 0) {
    Write-Host "Queueing episode FullRefresh requests..."

    $queued = 0
    foreach ($state in $episodeRefreshStates) {
        try {
            Invoke-JellyfinFullRefresh -ItemId $state.ItemId
            $state.EpisodeRefresh = "QUEUED"
            $queued++
        } catch {
            $state.EpisodeRefresh = "ERROR"
            $state.Result = "EPISODE_REFRESH_ERROR"
            $state.Message = $_.Exception.Message
        }

        if ($QueueDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $QueueDelayMilliseconds
        }
    }

    Write-Host "Episode refresh requests queued: $queued"

    $deadline = (Get-Date).AddSeconds($EpisodeTimeoutSeconds)
    do {
        Start-Sleep -Seconds $PollIntervalSeconds

        $episodes = @(Get-AllItemsByType -ItemType "Episode")
        $episodeByPath = New-PathMap -Items $episodes
        $pending = 0

        foreach ($state in $states) {
            if ($state.EpisodeRefresh -ne "QUEUED") {
                continue
            }

            if (-not $episodeByPath.ContainsKey($state.VideoPath)) {
                $pending++
                continue
            }

            $item = $episodeByPath[$state.VideoPath]
            $state.SeriesId = [string]$item.SeriesId

            if (Test-TargetNumbers -Item $item -Season $state.TargetSeason -Episode $state.TargetEpisode) {
                $state.EpisodeRefresh = "OK"
            } else {
                $pending++
            }
        }

        Write-Host "Episode refresh pending: $pending"
        if ($pending -eq 0) {
            break
        }
    } while ((Get-Date) -lt $deadline)

    foreach ($state in $states) {
        if ($state.EpisodeRefresh -eq "QUEUED") {
            $state.EpisodeRefresh = "TIMEOUT"
            $state.Result = "EPISODE_REFRESH_TIMEOUT"
            $state.Message = "Target season/episode was not reached before timeout"
        }
    }
}

$episodes = @(Get-AllItemsByType -ItemType "Episode")
$episodeByPath = New-PathMap -Items $episodes

foreach ($state in $states) {
    if (-not $state.ItemFound) {
        continue
    }
    if (-not $episodeByPath.ContainsKey($state.VideoPath)) {
        continue
    }

    $item = $episodeByPath[$state.VideoPath]
    $state.SeriesId = [string]$item.SeriesId
    $state.AfterSeason = $item.ParentIndexNumber
    $state.AfterEpisode = $item.IndexNumber
    $state.AfterSeasonId = [string]$item.SeasonId
}

$seriesIdSet = @{}
foreach ($state in $states) {
    if (-not $state.NfoExists -or -not $state.ItemFound) {
        continue
    }
    if ($null -eq $state.AfterSeason -or $null -eq $state.AfterEpisode) {
        continue
    }
    if ([int]$state.AfterSeason -ne [int]$state.TargetSeason) {
        continue
    }
    if ([int]$state.AfterEpisode -ne [int]$state.TargetEpisode) {
        continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.SeriesId)) {
        continue
    }

    $seriesIdSet[[string]$state.SeriesId] = $true
}

$seriesIds = @($seriesIdSet.Keys)

Write-Host ""
Write-Host "Series to refresh: $($seriesIds.Count)"

$seriesRefreshErrors = @{}

foreach ($seriesId in $seriesIds) {
    try {
        Invoke-JellyfinFullRefresh -ItemId $seriesId
        Write-Host "[SERIES QUEUED] $seriesId"
    } catch {
        $seriesRefreshErrors[$seriesId] = $_.Exception.Message
        Write-Warning "Series refresh failed: $seriesId"
    }

    if ($QueueDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $QueueDelayMilliseconds
    }
}

if ($seriesIds.Count -gt 0) {
    $deadline = (Get-Date).AddSeconds($SeriesTimeoutSeconds)

    do {
        Start-Sleep -Seconds $PollIntervalSeconds

        $episodes = @(Get-AllItemsByType -ItemType "Episode")
        $episodeByPath = New-PathMap -Items $episodes
        $seasons = @(Get-AllItemsByType -ItemType "Season")
        $seasonMap = New-SeasonMap -Seasons $seasons
        $pending = 0

        foreach ($state in $states) {
            if (-not $state.NfoExists -or -not $state.ItemFound) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$state.SeriesId)) {
                continue
            }
            if ($seriesRefreshErrors.ContainsKey([string]$state.SeriesId)) {
                continue
            }
            if (-not $episodeByPath.ContainsKey($state.VideoPath)) {
                $pending++
                continue
            }

            $item = $episodeByPath[$state.VideoPath]
            $state.AfterSeason = $item.ParentIndexNumber
            $state.AfterEpisode = $item.IndexNumber
            $state.AfterSeasonId = [string]$item.SeasonId

            if (-not (Test-TargetNumbers -Item $item -Season $state.TargetSeason -Episode $state.TargetEpisode)) {
                $pending++
                continue
            }

            $seasonKey = [string]$item.SeriesId + "|" + [string]([int]$state.TargetSeason)
            if (-not $seasonMap.ContainsKey($seasonKey)) {
                $pending++
                continue
            }

            $expectedSeason = $seasonMap[$seasonKey]
            $state.ExpectedSeasonId = [string]$expectedSeason.Id

            if ([string]$item.SeasonId -ne [string]$expectedSeason.Id) {
                $pending++
            }
        }

        Write-Host "Season relink pending: $pending"
        if ($pending -eq 0) {
            break
        }
    } while ((Get-Date) -lt $deadline)
}

$episodes = @(Get-AllItemsByType -ItemType "Episode")
$episodeByPath = New-PathMap -Items $episodes
$seasons = @(Get-AllItemsByType -ItemType "Season")
$seasonMap = New-SeasonMap -Seasons $seasons

foreach ($state in $states) {
    if (-not [string]::IsNullOrWhiteSpace($state.Result) -and $state.Result -notlike "DRY_RUN*") {
        continue
    }

    if (-not $state.NfoExists) {
        $state.Result = "NFO_MISSING"
        $state.Message = "NFO sidecar does not exist"
        continue
    }

    if (-not $state.ItemFound -or -not $episodeByPath.ContainsKey($state.VideoPath)) {
        $state.Result = "ITEM_NOT_FOUND"
        $state.Message = "Video path was not found in Jellyfin, including alternate versions"
        continue
    }

    $item = $episodeByPath[$state.VideoPath]
    $state.AfterSeason = $item.ParentIndexNumber
    $state.AfterEpisode = $item.IndexNumber
    $state.AfterSeasonId = [string]$item.SeasonId
    $state.SeriesId = [string]$item.SeriesId

    if (-not (Test-TargetNumbers -Item $item -Season $state.TargetSeason -Episode $state.TargetEpisode)) {
        $state.Result = "EPISODE_NOT_FIXED"
        $state.Message = "Episode season/number does not match the NFO target"
        continue
    }

    if ($seriesRefreshErrors.ContainsKey([string]$state.SeriesId)) {
        $state.SeriesRefresh = "ERROR"
        $state.Result = "SERIES_REFRESH_ERROR"
        $state.Message = [string]$seriesRefreshErrors[[string]$state.SeriesId]
        continue
    }

    $seasonKey = [string]$item.SeriesId + "|" + [string]([int]$state.TargetSeason)

    if (-not $seasonMap.ContainsKey($seasonKey)) {
        $state.SeriesRefresh = "FAILED"
        $state.Result = "TARGET_SEASON_NOT_FOUND"
        $state.Message = "Series does not contain the target season after refresh"
        continue
    }

    $expectedSeason = $seasonMap[$seasonKey]
    $state.ExpectedSeasonId = [string]$expectedSeason.Id

    if ([string]$item.SeasonId -ne [string]$expectedSeason.Id) {
        $state.SeriesRefresh = "FAILED"
        $state.Result = "SEASON_RELINK_FAILED"
        $state.Message = "ParentIndexNumber is correct but SeasonId still points to another season"
        continue
    }

    $state.SeriesRefresh = "OK"
    $state.Result = "OK"
    $state.Message = "Episode numbers and season link match the NFO target"
}

$states | Export-Csv -LiteralPath $ResultLogPath -NoTypeInformation -Encoding UTF8

$okCount = @($states | Where-Object { $_.Result -eq "OK" }).Count
$failCount = $states.Count - $okCount

Write-Host ""
Write-Host "Finished."
Write-Host "OK: $okCount"
Write-Host "Not OK: $failCount"
Write-Host "Result log: $ResultLogPath"
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "Review non-OK rows in the result log before retrying."
}
