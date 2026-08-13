$ErrorActionPreference = "Stop"

$helperPath = Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1"
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "TV audit helper not implemented yet: $helperPath"
}

. $helperPath

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

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Condition) {
        throw ("{0}: expected true" -f $Label)
    }
}

$folders = @(
    [pscustomobject]@{
        Name = "TV A"
        CollectionType = "tvshows"
        Locations = @("D:\TVA")
        ItemId = "tv-a"
        LibraryOptions = [pscustomobject]@{ EnableInternetProviders = $false }
    },
    [pscustomobject]@{
        Name = "Movies"
        CollectionType = "movies"
        Locations = @("D:\Movies")
        ItemId = "movies"
        LibraryOptions = [pscustomobject]@{ EnableInternetProviders = $true }
    },
    [pscustomobject]@{
        Name = "TV B"
        CollectionType = "tvshows"
        Locations = @("D:\TVB1", "D:\TVB2")
        ItemId = "tv-b"
        LibraryOptions = [pscustomobject]@{ EnableInternetProviders = $true }
    }
)

$tv = @(Get-TvaTvLibraries -VirtualFolders $folders)
Assert-Equal $tv.Count 2 "tv library count"
Assert-Equal $tv[0].Name "TV A" "first TV library"
Assert-Equal $tv[1].Locations.Count 2 "multi-root TV library"
Assert-Equal $tv[0].LibraryOptions.EnableInternetProviders $false "library options preserved"

Assert-Equal (Test-TvaVideoExtension -Path "x.mkv") $true "mkv accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.MP4") $true "case-insensitive mp4 accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.m4v") $true "m4v accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.avi") $true "avi accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.ts") $true "ts accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.webm") $true "webm accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.ass") $false "subtitle rejected"

$tempRoot = Join-Path $env:TEMP ("tva-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $nfoPath = Join-Path $tempRoot "episode.nfo"
    @'
<episodedetails>
  <title>Episode title</title>
  <season>3</season>
  <episode>7</episode>
  <plot>Episode plot</plot>
  <uniqueid type="tmdb" default="true">12345</uniqueid>
  <uniqueid type="imdb">tt1234567</uniqueid>
</episodedetails>
'@ | Set-Content -LiteralPath $nfoPath -Encoding UTF8

    $summary = Get-TvaNfoSummary -NfoPath $nfoPath
    Assert-Equal $summary.Season 3 "NFO season"
    Assert-Equal $summary.Episode 7 "NFO episode"
    Assert-Equal $summary.Title "Episode title" "NFO title"
    Assert-Equal $summary.Plot "Episode plot" "NFO plot"
    Assert-Equal $summary.UniqueIds.tmdb "12345" "NFO tmdb id"
    Assert-Equal $summary.UniqueIds.imdb "tt1234567" "NFO imdb id"

    $mediaDir = Join-Path $tempRoot "nested"
    New-Item -ItemType Directory -Path $mediaDir | Out-Null

    $videoPath = Join-Path $mediaDir "sample[02].mkv"
    [System.IO.File]::WriteAllBytes($videoPath, [byte[]](1, 2, 3, 4))

    $videoNfoPath = Join-Path $mediaDir "sample[02].nfo"
    @'
<episodedetails>
  <title>Inventory title</title>
  <season>1</season>
  <episode>2</episode>
</episodedetails>
'@ | Set-Content -LiteralPath $videoNfoPath -Encoding UTF8

    $subtitlePath = Join-Path $mediaDir "sample[02].ass"
    "x" | Set-Content -LiteralPath $subtitlePath -Encoding ASCII

    $files = @(Get-TvaVideoFiles -LibraryName "Test TV" -LibraryRoot $tempRoot)
    Assert-Equal $files.Count 1 "video inventory count"
    Assert-Equal $files[0].LibraryName "Test TV" "inventory library name"
    Assert-Equal $files[0].Length 4 "video length"
    Assert-Equal $files[0].SameNameNfoExists $true "same-name NFO found"
    Assert-Equal $files[0].NfoSummary.Episode 2 "inventory NFO episode"
    Assert-Equal $files[0].NfoReadError "" "inventory NFO read error"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$exporterPath = Join-Path $PSScriptRoot "..\scripts\export_jellyfin_tv_audit_12.ps1"
if (-not (Test-Path -LiteralPath $exporterPath -PathType Leaf)) {
    throw "TV audit exporter not implemented yet: $exporterPath"
}

$exporterText = [System.IO.File]::ReadAllText($exporterPath)
foreach ($forbidden in @(
    "-Method Post",
    "-Method Delete",
    "-Method Put",
    "-Method Patch",
    "/Refresh",
    "/AlternateSources"
)) {
    if ($exporterText.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Exporter contains forbidden mutating token: $forbidden"
    }
}

Assert-True ($exporterText.IndexOf("-Method Get", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "exporter uses GET"
Assert-True ($exporterText.IndexOf("CollectionType", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "exporter keeps library type"
Assert-True ($exporterText.IndexOf("VideoTypes=VideoFile", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "exporter has expanded Episode query"

Write-Host "PASS: TV audit helper and exporter safety tests"
