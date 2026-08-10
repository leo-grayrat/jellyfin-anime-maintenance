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
    throw "找不到动画根目录：$BangumiRoot"
}
if (-not (Test-Path -LiteralPath $RulesPath -PathType Leaf)) {
    throw "找不到规则文件：$RulesPath"
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
Write-Host "Jellyfin TV 动画 NFO 修正器"
if ($Apply) {
    Write-Host "模式：实际写入" -ForegroundColor Yellow
} else {
    Write-Host "模式：预演（不会写文件）" -ForegroundColor Cyan
}
Write-Host "动画根目录：$BangumiRoot"
Write-Host ""

foreach ($rule in $config.rules) {
    $dir = Join-Path $BangumiRoot $rule.relative_dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "[目录不存在，跳过] $($rule.work) :: $dir" -ForegroundColor DarkYellow
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
            Write-Warning "计算得到非法集数，已跳过：$($file.FullName)"
            continue
        }

        $nfoPath = [System.IO.Path]::ChangeExtension($file.FullName, ".nfo")
        $key = $nfoPath.ToLowerInvariant()

        if ($planned.ContainsKey($key)) {
            $old = $planned[$key]
            if ($old.Season -ne $season -or $old.Episode -ne $episode) {
                throw "规则冲突：$nfoPath 同时得到 S$($old.Season)E$($old.Episode) 与 S${season}E${episode}"
            }
            continue
        }
        $planned[$key] = @{ Season=$season; Episode=$episode; RuleId=$rule.id }

        if ((Test-Path -LiteralPath $nfoPath -PathType Leaf) -and -not $OverwriteExisting) {
            Write-Host "[已有 NFO，跳过] $($file.Name)" -ForegroundColor DarkYellow
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "SKIP_EXISTING" "已有 NFO；未覆盖"
            continue
        }

        $content = New-EpisodeNfoContent -Season $season -Episode $episode

        if ($Apply) {
            Write-Utf8NoBom -Path $nfoPath -Content $content
            Write-Host ("[写入] S{0:D2}E{1:D2}  {2}" -f $season,$episode,$file.Name) -ForegroundColor Green
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "WRITE" "已写入最小 episode NFO"
        } else {
            Write-Host ("[预演] S{0:D2}E{1:D2}  {2}" -f $season,$episode,$file.Name)
            Add-Log $rule.id $rule.work $file.FullName $nfoPath $season $episode "DRY_RUN" "预演，不写文件"
        }
    }
}

# 少数 Series 本身也需要最小 tvshow.nfo；目前只有 100 女友第 3 期。
foreach ($seriesNfo in $config.series_nfo) {
    $dir = Join-Path $BangumiRoot $seriesNfo.relative_dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "[Series 目录不存在，跳过] $($seriesNfo.work) :: $dir" -ForegroundColor DarkYellow
        continue
    }

    $nfoPath = Join-Path $dir "tvshow.nfo"
    if ((Test-Path -LiteralPath $nfoPath -PathType Leaf) -and -not $OverwriteExisting) {
        Write-Host "[已有 tvshow.nfo，跳过] $($seriesNfo.work)" -ForegroundColor DarkYellow
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "SKIP_EXISTING" "已有 tvshow.nfo；未覆盖"
        continue
    }

    $content = New-TvShowNfoContent -ProviderIds $seriesNfo.provider_ids
    if ($Apply) {
        Write-Utf8NoBom -Path $nfoPath -Content $content
        Write-Host "[写入 tvshow.nfo] $($seriesNfo.work)" -ForegroundColor Green
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "WRITE" "写入最小 provider IDs"
    } else {
        Write-Host "[预演 tvshow.nfo] $($seriesNfo.work)"
        Add-Log "series-nfo" $seriesNfo.work "" $nfoPath "" "" "DRY_RUN" "预演，不写文件"
    }
}

$log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8

$writeCount = @($log | Where-Object { $_.Action -eq "WRITE" }).Count
$dryCount = @($log | Where-Object { $_.Action -eq "DRY_RUN" }).Count
$skipCount = @($log | Where-Object { $_.Action -eq "SKIP_EXISTING" }).Count

Write-Host ""
Write-Host "完成。"
if ($Apply) {
    Write-Host "实际写入：$writeCount；已有 NFO 跳过：$skipCount"
} else {
    Write-Host "预演匹配：$dryCount；已有 NFO 跳过：$skipCount"
    Write-Host "确认无误后执行："
    Write-Host "  .\jellyfin_tv_nfo_fix.ps1 -Apply"
}
Write-Host "运行日志：$LogPath"
Write-Host ""
Write-Host "说明：2026 年 7 月仍在更新的异常命名已写成开放规则。新一集下载完成后再次运行本脚本即可自动为新文件生成对应 NFO。"
