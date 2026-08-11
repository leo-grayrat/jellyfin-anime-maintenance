# HISTORICAL EXPERIMENT - DO NOT USE AS CURRENT TOOL
# Status: RUN, FAILED TO CREATE SEASON 1.
# Purpose: test whether POST /Library/Media/Updated on the Fate series directory
# could cause Jellyfin to create a missing Season 1 object.
# Result: API accepted the update, but Season 1 was still absent after 180 s.
# Later source review showed this endpoint only queues refresh on an existing item;
# it is not equivalent to a structural rescan.

$ErrorActionPreference = "Stop"

$Server = "http://127.0.0.1:8096"
$ApiKey = "PASTE_API_KEY_HERE"
$SeriesId = "5593b2b4c108e8a7816754533aae41ef"

$Headers = @{
    Authorization = "MediaBrowser Client=`"fate-season-repair`", Device=`"PowerShell`", DeviceId=`"fate-season-repair`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-JellyfinGet {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Uri
    )

    return Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $Headers
}

function Get-SeriesItem {
    $Uri = "$Server/Items?Ids=$SeriesId&Fields=Path&EnableImages=false&EnableUserData=false"
    $Response = Invoke-JellyfinGet -Uri $Uri

    if ($Response.Items.Count -eq 0) {
        throw "Fate/strange Fake series was not found."
    }

    return $Response.Items[0]
}

function Get-Seasons {
    $Uri = "$Server/Items?ParentId=$SeriesId&IncludeItemTypes=Season&Recursive=false&Limit=100&EnableImages=false&EnableUserData=false"
    $Response = Invoke-JellyfinGet -Uri $Uri
    return @($Response.Items)
}

function Get-FateEpisodes {
    $StartIndex = 0
    $Limit = 500
    $AllEpisodes = @()

    do {
        $Uri = "$Server/Items?Recursive=true&StartIndex=$StartIndex&Limit=$Limit&IncludeItemTypes=Episode&VideoTypes=VideoFile&Fields=Path&EnableImages=false&EnableUserData=false"
        $Response = Invoke-JellyfinGet -Uri $Uri
        $Page = @($Response.Items)

        $AllEpisodes += @(
            $Page |
            Where-Object {
                [string]$_.SeriesId -eq $SeriesId
            }
        )

        $StartIndex += $Page.Count
    } while (
        $Page.Count -gt 0 -and
        $StartIndex -lt $Response.TotalRecordCount
    )

    return @($AllEpisodes)
}

function Show-State {
    $Seasons = @(Get-Seasons)
    $Episodes = @(Get-FateEpisodes)

    Write-Host ""
    Write-Host "Seasons:"
    Write-Host ""

    if ($Seasons.Count -eq 0) {
        Write-Host "(none)"
    }
    else {
        $Seasons |
            Sort-Object IndexNumber |
            Select-Object Name, IndexNumber, Id |
            Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "Episodes:"
    Write-Host ""

    $Episodes |
        Sort-Object ParentIndexNumber, IndexNumber |
        Select-Object `
            IndexNumber,
            ParentIndexNumber,
            SeasonName,
            SeasonId,
            Id,
            Path |
        Format-Table -AutoSize

    return @{
        Seasons  = $Seasons
        Episodes = $Episodes
    }
}

Write-Host ""
Write-Host "=== Fate/strange Fake Season Repair ==="

$Series = Get-SeriesItem

Write-Host ""
Write-Host "Series name: $($Series.Name)"
Write-Host "Series path: $($Series.Path)"
Write-Host "Series ID:   $SeriesId"

Write-Host ""
Write-Host "=== Before filesystem refresh ==="

$Before = Show-State

$Season1Before = @(
    $Before.Seasons |
    Where-Object {
        $_.IndexNumber -eq 1
    }
)

if ($Season1Before.Count -gt 0) {
    Write-Host ""
    Write-Host "Season 1 already exists."
    Write-Host "No filesystem refresh is needed."
}
else {
    Write-Host ""
    Write-Host "Season 1 does not exist."
    Write-Host "Reporting the series directory as modified..."

    $Body = @{
        Updates = @(
            @{
                Path       = $Series.Path
                UpdateType = "Modified"
            }
        )
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Method Post `
        -Uri "$Server/Library/Media/Updated" `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body |
        Out-Null

    Write-Host "Filesystem update was reported."
    Write-Host ""
    Write-Host "Waiting for Jellyfin to create Season 1..."

    $Season1 = $null

    for ($i = 1; $i -le 36; $i++) {
        Start-Sleep -Seconds 5
        $Seasons = @(Get-Seasons)

        $Season1 = @(
            $Seasons |
            Where-Object {
                $_.IndexNumber -eq 1
            }
        ) |
        Select-Object -First 1

        if ($null -ne $Season1) {
            Write-Host "Check $i/36 : Season 1 found."
            break
        }
        else {
            Write-Host "Check $i/36 : Season 1 not found yet."
        }
    }

    if ($null -eq $Season1) {
        Write-Host ""
        Write-Host "=== Result ==="
        Write-Host "FAILED: filesystem refresh did not create Season 1."
        Write-Host ""
        Write-Host "No files were modified by this script."
        Write-Host "Do not rerun the full 243-episode batch."
        return
    }
}

$Seasons = @(Get-Seasons)

$Season1 = @(
    $Seasons |
    Where-Object {
        $_.IndexNumber -eq 1
    }
) |
Select-Object -First 1

if ($null -eq $Season1) {
    throw "Season 1 could not be resolved."
}

$ExpectedSeasonId = [string]$Season1.Id

Write-Host ""
Write-Host "Season 1 ID: $ExpectedSeasonId"
Write-Host ""
Write-Host "Refreshing Fate/strange Fake series metadata..."

$RefreshUri = "$Server/Items/$SeriesId/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=false&replaceAllImages=false"

Invoke-RestMethod `
    -Method Post `
    -Uri $RefreshUri `
    -Headers $Headers |
    Out-Null

Write-Host "Series refresh queued."
Write-Host ""
Write-Host "Waiting for S01E01-S01E13 to link to Season 1..."

$FinalEpisodes = @()

for ($i = 1; $i -le 36; $i++) {
    Start-Sleep -Seconds 5
    $Episodes = @(Get-FateEpisodes)

    $Season1Episodes = @(
        $Episodes |
        Where-Object {
            $_.ParentIndexNumber -eq 1 -and
            $_.IndexNumber -ge 1 -and
            $_.IndexNumber -le 13
        }
    )

    $CorrectLinks = @(
        $Season1Episodes |
        Where-Object {
            [string]$_.SeasonId -eq $ExpectedSeasonId
        }
    )

    Write-Host (
        "Check $i/36 : " +
        "$($CorrectLinks.Count)/13 episodes linked to Season 1"
    )

    if ($CorrectLinks.Count -eq 13) {
        $FinalEpisodes = $Episodes
        break
    }

    $FinalEpisodes = $Episodes
}

Write-Host ""
Write-Host "=== Final State ==="

$FinalEpisodes |
    Sort-Object ParentIndexNumber, IndexNumber |
    Select-Object `
        IndexNumber,
        ParentIndexNumber,
        SeasonName,
        SeasonId,
        Path |
    Format-Table -AutoSize

$FinalSeason1 = @(
    $FinalEpisodes |
    Where-Object {
        $_.ParentIndexNumber -eq 1 -and
        $_.IndexNumber -ge 1 -and
        $_.IndexNumber -le 13 -and
        [string]$_.SeasonId -eq $ExpectedSeasonId
    }
)

Write-Host ""
Write-Host "=== Result ==="

if ($FinalSeason1.Count -eq 13) {
    Write-Host "SUCCESS."
    Write-Host "All 13 Fate/strange Fake episodes are linked to Season 1."
}
else {
    Write-Host "PARTIAL FAILURE."
    Write-Host "$($FinalSeason1.Count)/13 episodes are linked to Season 1."
    Write-Host "Please send the complete output back for analysis."
}
