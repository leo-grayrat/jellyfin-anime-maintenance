param(
    [string]$BangumiRoot = "D:\Bangumi",
    [switch]$Apply,
    [switch]$OverwriteExisting,
    [string]$RulesPath = (Join-Path $PSScriptRoot "..\rules\jellyfin_tv_nfo_rules.json"),
    [string]$LogPath = (Join-Path $PSScriptRoot "..\jellyfin_tv_nfo_run_log.csv")
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function New-EpisodeNfoContent {
    param([int]$Season, [int]$Episode)
    return @"
<?xml version="1.0" encoding="utf-8"?>
<episodedetails>
  <season>$Season</season>
  <episode>$Episode</episode>
</episodedetails>
"@
}

function New-TvShowNfoContent {
    param($ProviderIds)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<tvshow>')
    if ($ProviderIds.tmdbid)  { $lines.Add("  <tmdbid>$($ProviderIds.tmdbid)</tmdbid>") }
    if ($ProviderIds.tvdbid)  { $lines.Add("  <tvdbid>$($ProviderIds.tvdbid)</tvdbid>") }
    if ($ProviderIds.imdb_id) { $lines.Add("  <imdb_id>$($ProviderIds.imdb_id)</imdb_id>") }
    $lines.Add('</tvshow>')
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if (-not (Test-Path -LiteralPath $BangumiRoot -PathType Container)) {
    throw "Anime root directory not found: $BangumiRoot"
}
if (-not (Test-Path -LiteralPath $RulesPath -PathType Leaf)) {
    throw "Rules file not found: $RulesPath"
}

$config = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$planned = @{}
$log = New-Object System.Collections.Generic.List[object]

function Add-Log {
    param($RuleId, $Work, $VideoPath, $NfoPath, $Season, $Episode, $Action, $Message)
    $log.Add([pscustomobject]@{
        RuleId = $RuleId
        Work = $Work
        VideoPath = $VideoPath
        NfoPath = $NfoPath
        Season = $Season
        Episode = $Episode
        Action = $Action
        Message = $Message
    })
}

Write-Host ""
Write-Host "Jellyfin TV Anime NFO Fixer"
if ($Apply) {
    Write-Host "Mode: APPLY (files will be written)" -ForegroundColor Yellow
} else {
    Write-Host "Mode: DRY RUN (no files will be written)" -ForegroundColor Cyan
}
Write-Host "Anime root: $BangumiRoot"
Write-Host ""

foreach ($rule in $config.rules) {
    $dir = Join-Path $BangumiRoot $rule.relative_dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "[SKIP missing directory] $($rule.work) :: $dir" -ForegroundColor DarkYellow
        continue
    }

    if ($rule.recursive) {
        $files = Get-ChildItem -LiteralPath $dir -File -Recurse
    } else {
        $files = Get-ChildItem -LiteralPath $dir -File
    }

    foreach ($file in $files) {
        if ($file.Extension -notin @(".mkv", ".mp4", ".avi", ".m2ts", ".ts")) { continue }
        if ($file.Name -notmatch $rule.regex) { continue }

        if ($null -ne $rule.fixed_episode) {
            $episode = [int]$rule.fixed_episode
        } else {
            if (-not $Matches.ContainsKey("ep")) { continue }
            $raw = [int]$Matches["ep"]
            if ($null -ne $rule.min_raw -and $raw -lt [int]$rule.min_raw) { continue }
            if ($null -ne $rule.max_raw -and $raw -gt [int]$rule.max_raw) { continue }
            $episode = $raw - [int]$rule.offset
        }

        $season = [int]$rule.season
        if ($episode -lt 0) {
            Write-Warning "Calculated an invalid episode number; skipped: $($file.FullName)"
            continue
        }

        $nfoPath = [System.IO.Path]::ChangeExtension($file.FullName, ".nfo")
        $key = $nfoPath.ToLowerInvariant()

        if ($planned.ContainsKey($key)) {
            $old = $planned[$key]
            if ($old.Season -ne $season -or $old.Episode -ne $episode) {
                throw "Rule conflict: $nfoPath maps to both S$($old.Season)E$($old.Episode) and S${season}E${episode}"
            }
            continue
        }
        $planned[$key] = @{ Season=$season; Episode=$episode; RuleId=$rule.id }

        if ((Test-Path -LiteralPath $nfoPath -PathType Leaf) -and -not $OverwriteExisting) {
            Write-Host "[SKIP existing NFO] $($file.Name)" -ForegroundColor DarkYellow
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "SKIP_EXISTING" "Existing NFO was not overwritten"
            continue
        }

        $content = New-EpisodeNfoContent -Season $season -Episode $episode

        if ($Apply) {
            Write-Utf8NoBom -Path $nfoPath -Content $content
            Write-Host ("[WRITE] S{0:D2}E{1:D2}  {2}" -f $season,$episode,$file.Name) -ForegroundColor Green
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "WRITE" "Minimal episode NFO written"
        } else {
            Write-Host ("[DRY RUN] S{0:D2}E{1:D2}  {2}" -f $season,$episode,$file.Name)
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "DRY_RUN" "Dry run only; no file written"
        }
    }
}

# A small number of series also need a minimal tvshow.nfo with provider IDs.
foreach ($seriesNfo in $config.series_nfo) {
    $dir = Join-Path $BangumiRoot $seriesNfo.relative_dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "[SKIP missing series directory] $($seriesNfo.work) :: $dir" -ForegroundColor DarkYellow
        continue
    }

    $nfoPath = Join-Path $dir "tvshow.nfo"
    if ((Test-Path -LiteralPath $nfoPath -PathType Leaf) -and -not $OverwriteExisting) {
        Write-Host "[SKIP existing tvshow.nfo] $($seriesNfo.work)" -ForegroundColor DarkYellow
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "SKIP_EXISTING" "Existing tvshow.nfo was not overwritten"
        continue
    }

    $content = New-TvShowNfoContent -ProviderIds $seriesNfo.provider_ids
    if ($Apply) {
        Write-Utf8NoBom -Path $nfoPath -Content $content
        Write-Host "[WRITE tvshow.nfo] $($seriesNfo.work)" -ForegroundColor Green
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "WRITE" "Minimal provider IDs written"
    } else {
        Write-Host "[DRY RUN tvshow.nfo] $($seriesNfo.work)"
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "DRY_RUN" "Dry run only; no file written"
    }
}

$log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8

$writeCount = @($log | Where-Object { $_.Action -eq "WRITE" }).Count
$dryCount = @($log | Where-Object { $_.Action -eq "DRY_RUN" }).Count
$skipCount = @($log | Where-Object { $_.Action -eq "SKIP_EXISTING" }).Count

Write-Host ""
Write-Host "Finished."
if ($Apply) {
    Write-Host "Written: $writeCount; existing NFO skipped: $skipCount"
} else {
    Write-Host "Dry-run matches: $dryCount; existing NFO skipped: $skipCount"
    Write-Host "If the preview is correct, run:"
    Write-Host "  .\scripts\jellyfin_tv_nfo_fix.ps1 -Apply"
}
Write-Host "Run log: $LogPath"
Write-Host ""
Write-Host "Future-episode rules are enabled for selected currently-airing series. Re-run this script after new episodes are added."
