$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Condition) {
        throw ("{0}: expected true" -f $Label)
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Actual -ne $Expected) {
        throw ("{0}: expected [{1}], got [{2}]" -f $Label, $Expected, $Actual)
    }
}

$analyzerPath = Join-Path $PSScriptRoot "..\scripts\analyze_jellyfin_tv_audit.ps1"
if (-not (Test-Path -LiteralPath $analyzerPath -PathType Leaf)) {
    throw "Analyzer not implemented yet: $analyzerPath"
}

$tempRoot = Join-Path $env:TEMP ("tva-analyzer-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $inputPath = Join-Path $tempRoot "audit.json"
    $csvPath = Join-Path $tempRoot "ledger.csv"
    $summaryPath = Join-Path $tempRoot "summary.md"

    $audit = [ordered]@{
        SchemaVersion = 1
        NormalItems = @(
            [pscustomobject]@{
                Type = "Series"
                Id = "series-a"
                Name = "Series A"
                LibraryName = "TV"
                Path = "D:\TV\Series A"
                ProviderIds = [pscustomobject]@{ Tmdb = "100" }
                Overview = "Series overview"
                ImageTags = [pscustomobject]@{}
            },
            [pscustomobject]@{
                Type = "Season"
                Id = "season-a1"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                IndexNumber = 1
                Name = "Season 1"
                Path = ""
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
            },
            [pscustomobject]@{
                Type = "Season"
                Id = "season-bad"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                IndexNumber = 2026
                Name = "Season 2026"
                Path = ""
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
            },
            [pscustomobject]@{
                Type = "Season"
                Id = "season-extra"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                IndexNumber = $null
                Name = "Bonus"
                Path = "D:\TV\Series A\Bonus"
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
            },
            [pscustomobject]@{
                Type = "Episode"
                Id = "ep-a1"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                Path = "D:\TV\Series A\a1.mkv"
            },
            [pscustomobject]@{
                Type = "Series"
                Id = "series-test"
                Name = "Test Series"
                LibraryName = "test"
                Path = "D:\Test"
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
            }
        )
        ExpandedEpisodes = @(
            [pscustomobject]@{
                Type = "Episode"
                Id = "ep-a1"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                ParentIndexNumber = 1
                IndexNumber = 1
                Name = "Repeated title"
                Path = "D:\TV\Series A\a1.mkv"
                ProviderIds = [pscustomobject]@{ Tmdb = "101" }
                Overview = "Episode overview"
                ImageTags = [pscustomobject]@{ Primary = "img" }
                MediaSourceCount = 2
            },
            [pscustomobject]@{
                Type = "Episode"
                Id = "ep-a2"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                ParentIndexNumber = 1
                IndexNumber = 2
                Name = "Repeated title"
                Path = "D:\TV\Series A\a2.mkv"
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{ Primary = "img" }
                MediaSourceCount = 1
            },
            [pscustomobject]@{
                Type = "Episode"
                Id = "extra-1"
                SeriesId = "series-a"
                SeriesName = "Series A"
                LibraryName = "TV"
                ParentIndexNumber = 1
                IndexNumber = 3
                Name = "NCOP"
                Path = "D:\TV\Series A\Bonus\NCOP.mkv"
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
                MediaSourceCount = 1
            },
            [pscustomobject]@{
                Type = "Episode"
                Id = "test-ep"
                SeriesId = "series-test"
                SeriesName = "Test Series"
                LibraryName = "test"
                ParentIndexNumber = 1
                IndexNumber = 1
                Name = "Test"
                Path = "D:\Test\test.mkv"
                ProviderIds = [pscustomobject]@{}
                Overview = ""
                ImageTags = [pscustomobject]@{}
                MediaSourceCount = 1
            }
        )
        FilesystemVideos = @(
            [pscustomobject]@{
                LibraryName = "TV"
                Path = "D:\TV\Series A\a1.mkv"
                SameNameNfoExists = $true
                NfoSummary = [pscustomobject]@{ Season = 1; Episode = 1 }
            },
            [pscustomobject]@{
                LibraryName = "TV"
                Path = "D:\TV\Series A\a2.mkv"
                SameNameNfoExists = $true
                NfoSummary = [pscustomobject]@{ Season = 1; Episode = 2 }
            },
            [pscustomobject]@{
                LibraryName = "TV"
                Path = "D:\TV\Series A\Bonus\NCOP.mkv"
                SameNameNfoExists = $false
                NfoSummary = $null
            },
            [pscustomobject]@{
                LibraryName = "TV"
                Path = "D:\TV\Series A\orphan.mkv"
                SameNameNfoExists = $false
                NfoSummary = $null
            },
            [pscustomobject]@{
                LibraryName = "test"
                Path = "D:\Test\test.mkv"
                SameNameNfoExists = $false
                NfoSummary = $null
            }
        )
    }

    $json = $audit | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($inputPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    & $analyzerPath -Input $inputPath -OutputCsv $csvPath -OutputSummary $summaryPath

    Assert-True (Test-Path -LiteralPath $csvPath -PathType Leaf) "ledger created"
    Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) "summary created"

    $rows = @(Import-Csv -LiteralPath $csvPath)
    Assert-Equal $rows.Count 8 "test library excluded and season rows included"

    $series = $rows | Where-Object { $_.ItemType -eq "Series" -and $_.SeriesId -eq "series-a" }
    Assert-True ($series.IssueLabels -match "SERIES_METADATA_MISSING_PRIMARY_IMAGE") "series image issue"

    $standardSeason = $rows | Where-Object { $_.ItemId -eq "season-a1" }
    Assert-Equal $standardSeason.IssueLabels "" "standard season clean"

    $badSeason = $rows | Where-Object { $_.ItemId -eq "season-bad" }
    Assert-True ($badSeason.IssueLabels -match "STRUCTURE_SUSPICIOUS_SEASON_NUMBER") "suspicious season number"

    $extraSeason = $rows | Where-Object { $_.ItemId -eq "season-extra" }
    Assert-True ($extraSeason.IssueLabels -match "STRUCTURE_SEASON_MISSING_INDEX") "extra season missing index"
    Assert-True ($extraSeason.IssueLabels -match "REVIEW_EXTRAS") "extra season review"

    $visible = $rows | Where-Object { $_.ItemId -eq "ep-a1" }
    Assert-Equal $visible.VisibleInNormalView "True" "visible episode"
    Assert-Equal $visible.CorrectionTargetNfo "True" "visible correction target"
    Assert-Equal $visible.NfoStructureMatches "True" "visible NFO matches"
    Assert-True ($visible.IssueLabels -match "METADATA_REPEATED_TITLE_ACROSS_EPISODES") "visible repeated title"

    $hidden = $rows | Where-Object { $_.ItemId -eq "ep-a2" }
    Assert-Equal $hidden.VisibleInNormalView "False" "hidden episode"
    Assert-True ($hidden.IssueLabels -match "STRUCTURE_HIDDEN_ALTERNATE") "hidden structure issue"
    Assert-True ($hidden.IssueLabels -match "METADATA_MISSING_PROVIDER_ID") "hidden provider issue"
    Assert-True ($hidden.IssueLabels -match "METADATA_MISSING_OVERVIEW") "hidden overview issue"

    $extra = $rows | Where-Object { $_.ItemId -eq "extra-1" }
    Assert-True ($extra.IssueLabels -match "REVIEW_EXTRAS") "extra review"
    Assert-True ($extra.IssueLabels -match "REVIEW_NON_TARGET_HIDDEN") "non-target hidden review"

    $orphan = $rows | Where-Object { $_.ItemType -eq "FilesystemVideo" }
    Assert-True ($orphan.IssueLabels -match "FILESYSTEM_NOT_IN_JELLYFIN") "filesystem-only issue"

    $summary = [System.IO.File]::ReadAllText($summaryPath)
    Assert-True ($summary -match "Season rows: 3") "summary season count"
    Assert-True ($summary -match "Correction-target NFO rows: 2") "summary correction count"
    Assert-True ($summary -match "Hidden Episode rows: 2") "summary hidden count"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: TV audit analyzer tests"