param(
    [string]$BangumiRoot = "D:\Bangumi",
    [switch]$Apply,
    [switch]$OverwriteExisting,
    [string]$RulesPath = (Join-Path $PSScriptRoot "..\rules\jellyfin_tv_nfo_rules.json"),
    [string]$LogPath = (Join-Path $PSScriptRoot "jellyfin_tv_nfo_run_log.csv")
)

$ErrorActionPreference = "Stop"

# This script writes only minimal Jellyfin episode NFO files.
# It does not rename, move, or delete media files.

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function New-EpisodeNfoContent {
    param([int]$Season,[int]$Episode)
    return @"
<?xml version="1.0" encoding="utf-8"?>
<episodedetails>
  <season>$Season</season>
  <episode>$Episode</episode>
</episodedetails>
"@
}

$config = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$log = @()

foreach ($rule in $config.rules) {
    $dir = Join-Path $BangumiRoot $rule.relative_dir
    if (-not (Test-Path $dir)) { continue }

    $files = Get-ChildItem -LiteralPath $dir -File -Recurse
    foreach ($file in $files) {
        if ($file.Extension -notin @('.mkv','.mp4','.avi','.ts')) { continue }
        if ($file.Name -notmatch $rule.regex) { continue }

        $episode = [int]$Matches['ep'] - [int]$rule.offset
        $season = [int]$rule.season
        $nfo = [System.IO.Path]::ChangeExtension($file.FullName,'.nfo')

        if ((Test-Path $nfo) -and (-not $OverwriteExisting)) { continue }

        $content = New-EpisodeNfoContent $season $episode
        if ($Apply) { Write-Utf8NoBom $nfo $content }

        $log += [pscustomobject]@{
            File=$file.FullName
            Season=$season
            Episode=$episode
            Action=if($Apply){'WRITE'}else{'DRY_RUN'}
        }
    }
}

$log | Export-Csv $LogPath -NoTypeInformation -Encoding UTF8
