# Jellyfin TV Audit Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Jellyfin 12 read-only TV-only exporter that captures library/provider configuration, normal TV items, expanded/hidden Episode items, and filesystem/NFO facts in one repeatable JSON snapshot.

**Architecture:** Keep the existing generic `export_jellyfin_library_12.ps1` unchanged. Add a focused `tv_audit_common.ps1` helper for TV-library flattening, safe path/NFO handling, and native long-path filesystem enumeration; add `export_jellyfin_tv_audit_12.ps1` as the orchestration layer that performs only GET requests, partitions API reads by TV library, and writes one versioned JSON file. Tests exercise helper behavior without requiring a Jellyfin server, while the existing PowerShell 5.1 parser check is extended to the new files.

**Tech Stack:** Windows PowerShell 5.1, Jellyfin 12 HTTP API, PowerShell JSON/XML handling, small embedded C# P/Invoke helper for Windows long-path enumeration/read-only file access.

## Global Constraints

- Scope is `CollectionType = tvshows` only; movie libraries are excluded.
- The exporter performs only Jellyfin GET requests.
- It never refreshes, identifies, deletes, updates, merges, writes NFO, writes media, or writes the Jellyfin database.
- Its only persistent write is the requested JSON export file.
- API keys must never be serialized into the export.
- Existing `scripts/export_jellyfin_library_12.ps1` remains a lightweight generic exporter and is not expanded for this job.
- Expanded Episode discovery uses the already-validated `VideoTypes=VideoFile` query behavior.
- Known long subtitle-group paths must not be silently skipped because of legacy `MAX_PATH` behavior.
- Script sources covered by the Windows PowerShell 5.1 compatibility test remain ASCII-only.
- Default output is `%USERPROFILE%\Desktop\jellyfin-tv-audit-export.json`.
- Export schema version starts at `1`.

---

### Task 1: Add TV audit helper contracts and tests

**Files:**
- Create: `scripts/lib/tv_audit_common.ps1`
- Create: `tests/test_tv_audit_common.ps1`
- Modify: `tests/check_windows_powershell_compat.ps1`

**Interfaces:**
- Produces: `Get-TvaTvLibraries -VirtualFolders <object> -> object[]`
- Produces: `Get-TvaNfoSummary -NfoPath <string> -> pscustomobject`
- Produces: `Test-TvaVideoExtension -Path <string> -> bool`
- Produces: `Initialize-TvaNativeFileSystem`
- Produces: `Get-TvaVideoFiles -LibraryName <string> -LibraryRoot <string> -> object[]`
- `Get-TvaVideoFiles` rows expose `LibraryName`, `LibraryRoot`, `Path`, `Extension`, `Length`, `LastWriteTime`, `SameNameNfoPath`, `SameNameNfoExists`, `NfoSummary`, and `NfoReadError`.

- [ ] **Step 1: Write failing helper tests**

Create `tests/test_tv_audit_common.ps1` with deterministic local tests that dot-source `scripts/lib/tv_audit_common.ps1` and verify:

```powershell
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1")

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw ("{0}: expected [{1}], got [{2}]" -f $Label, $Expected, $Actual)
    }
}

$folders = @(
    [pscustomobject]@{ Name = "TV A"; CollectionType = "tvshows"; Locations = @("D:\TVA"); ItemId = "tv-a" },
    [pscustomobject]@{ Name = "Movies"; CollectionType = "movies"; Locations = @("D:\Movies"); ItemId = "movies" },
    [pscustomobject]@{ Name = "TV B"; CollectionType = "tvshows"; Locations = @("D:\TVB1", "D:\TVB2"); ItemId = "tv-b" }
)
$tv = @(Get-TvaTvLibraries -VirtualFolders $folders)
Assert-Equal $tv.Count 2 "tv library count"
Assert-Equal $tv[0].Name "TV A" "first TV library"
Assert-Equal $tv[1].Locations.Count 2 "multi-root TV library"

Assert-Equal (Test-TvaVideoExtension -Path "x.mkv") $true "mkv accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.MP4") $true "case-insensitive mp4 accepted"
Assert-Equal (Test-TvaVideoExtension -Path "x.ass") $false "subtitle rejected"

$tempRoot = Join-Path $env:TEMP ("tva-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $nfo = Join-Path $tempRoot "episode.nfo"
    @'
<episodedetails>
  <title>Episode title</title>
  <season>3</season>
  <episode>7</episode>
  <plot>Episode plot</plot>
  <uniqueid type="tmdb" default="true">12345</uniqueid>
  <uniqueid type="imdb">tt1234567</uniqueid>
</episodedetails>
'@ | Set-Content -LiteralPath $nfo -Encoding UTF8

    $summary = Get-TvaNfoSummary -NfoPath $nfo
    Assert-Equal $summary.Season 3 "NFO season"
    Assert-Equal $summary.Episode 7 "NFO episode"
    Assert-Equal $summary.Title "Episode title" "NFO title"
    Assert-Equal $summary.Plot "Episode plot" "NFO plot"
    Assert-Equal $summary.UniqueIds.tmdb "12345" "NFO tmdb id"
    Assert-Equal $summary.UniqueIds.imdb "tt1234567" "NFO imdb id"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: TV audit helper tests"
```

- [ ] **Step 2: Run tests and confirm they fail because helpers do not exist**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tv_audit_common.ps1
```

Expected: FAIL at the first missing `Get-Tva*` function.

- [ ] **Step 3: Implement the minimal pure helper functions**

Create `scripts/lib/tv_audit_common.ps1` with:

```powershell
$ErrorActionPreference = "Stop"

function Get-TvaTvLibraries {
    param([Parameter(Mandatory = $true)]$VirtualFolders)

    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($VirtualFolders)

    while ($queue.Count -gt 0) {
        $value = $queue.Dequeue()
        if ($null -eq $value) { continue }

        $hasName = $null -ne $value.PSObject.Properties['Name']
        $hasType = $null -ne $value.PSObject.Properties['CollectionType']
        $hasLocations = $null -ne $value.PSObject.Properties['Locations']
        if ($hasName -and $hasType -and $hasLocations) {
            if ([string]$value.CollectionType -eq "tvshows") {
                $result += $value
            }
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            foreach ($item in $value) { $queue.Enqueue($item) }
            continue
        }

        throw "Unexpected Jellyfin virtual-folder response shape."
    }

    return @($result | Sort-Object Name)
}

function Test-TvaVideoExtension {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    return @(".mkv", ".mp4", ".m4v", ".avi", ".ts", ".webm") -contains $ext
}
```

Add `Get-TvaNfoSummary` so malformed/missing optional tags return empty fields rather than aborting the entire export; an actually unreadable XML file throws and is caught by `Get-TvaVideoFiles` into `NfoReadError`.

- [ ] **Step 4: Extend the PowerShell 5.1 parser/ASCII test**

Append the two new script paths to `tests/check_windows_powershell_compat.ps1`:

```powershell
(Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1"),
(Join-Path $PSScriptRoot "..\scripts\export_jellyfin_tv_audit_12.ps1")
```

The exporter file will be added in Task 2; until then run only `test_tv_audit_common.ps1`.

- [ ] **Step 5: Run helper tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tv_audit_common.ps1
```

Expected: `PASS: TV audit helper tests`.

- [ ] **Step 6: Commit helper/test foundation**

```bash
git add scripts/lib/tv_audit_common.ps1 tests/test_tv_audit_common.ps1 tests/check_windows_powershell_compat.ps1
git commit -m "test: define TV audit export helpers"
```

---

### Task 2: Implement read-only Jellyfin TV API export

**Files:**
- Create: `scripts/export_jellyfin_tv_audit_12.ps1`
- Modify: `tests/test_tv_audit_common.ps1`

**Interfaces:**
- Consumes: `Get-TvaTvLibraries`
- Produces JSON keys: `SchemaVersion`, `ExportedAt`, `Server`, `TvLibraries`, `NormalItems`, `ExpandedEpisodes`, `FilesystemVideos`
- Produces per API row `LibraryName` and `LibraryItemId` annotations so records remain attributable after export.

- [ ] **Step 1: Add a static safety test for mutating HTTP verbs/endpoints**

Extend `tests/test_tv_audit_common.ps1` to read `scripts/export_jellyfin_tv_audit_12.ps1` once it exists and fail if it contains explicit mutating calls:

```powershell
$exporterPath = Join-Path $PSScriptRoot "..\scripts\export_jellyfin_tv_audit_12.ps1"
$exporterText = [System.IO.File]::ReadAllText($exporterPath)
foreach ($forbidden in @("-Method Post", "-Method Delete", "-Method Put", "-Method Patch", "/Refresh", "/AlternateSources")) {
    if ($exporterText.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Exporter contains forbidden mutating token: $forbidden"
    }
}
```

- [ ] **Step 2: Implement authorization and GET-only API wrappers**

The exporter begins with:

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [string]$Output = "$env:USERPROFILE\Desktop\jellyfin-tv-audit-export.json"
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')
. (Join-Path $PSScriptRoot "lib\tv_audit_common.ps1")

$Headers = @{
    Authorization = "MediaBrowser Client=`"tv-audit-export`", Device=`"PowerShell`", DeviceId=`"tv-audit-export`", Version=`"1.0`", Token=`"$ApiKey`""
}

function Invoke-TvaJellyfinGet {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}
```

No generic method parameter is exposed, so callers cannot accidentally switch the helper to POST/DELETE.

- [ ] **Step 3: Implement paged library-scoped item retrieval**

Add:

```powershell
function Get-TvaPagedItems {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryItemId,
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$IncludeItemTypes,
        [switch]$ExpandedVideoFiles
    )
```

It requests `ParentId=$LibraryItemId&Recursive=true`, `Limit=500`, and fields:

```text
Path,ProviderIds,Overview,PremiereDate,DateCreated,OriginalTitle,SortName,
ProductionYear,MediaSources,MediaSourceCount,SeriesId,SeriesName,SeasonId,
SeasonName,ParentId,ImageTags,BackdropImageTags
```

When `ExpandedVideoFiles` is set, append `&VideoTypes=VideoFile` and query only `Episode`.

For every returned item, add properties:

```powershell
LibraryName
LibraryItemId
```

before accumulating it.

- [ ] **Step 4: Filter virtual folders before any item reads**

Flow:

```powershell
$virtualFolders = Invoke-TvaJellyfinGet -Uri "$Server/Library/VirtualFolders"
$tvLibraries = @(Get-TvaTvLibraries -VirtualFolders $virtualFolders)
if ($tvLibraries.Count -eq 0) { throw "No tvshows libraries found." }
```

This is the primary guarantee that movie libraries never enter `NormalItems`, `ExpandedEpisodes`, or `FilesystemVideos`.

- [ ] **Step 5: Build normal and expanded API snapshots**

For each TV library:

```powershell
$normal += @(Get-TvaPagedItems -LibraryItemId $library.ItemId -LibraryName $library.Name -IncludeItemTypes "Series,Season,Episode")
$expanded += @(Get-TvaPagedItems -LibraryItemId $library.ItemId -LibraryName $library.Name -IncludeItemTypes "Episode" -ExpandedVideoFiles)
```

Print counts per library and global totals, but do not make any mutation request.

- [ ] **Step 6: Build server/library export objects without secrets**

Use `/System/Info` for server version/name/product fields. For `TvLibraries`, retain each TV virtual folder including `LibraryOptions`; do not add request headers or `$ApiKey` anywhere in the object graph.

- [ ] **Step 7: Run parser and static safety tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tv_audit_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

Expected: both PASS.

- [ ] **Step 8: Commit API-only exporter checkpoint**

```bash
git add scripts/export_jellyfin_tv_audit_12.ps1 tests/test_tv_audit_common.ps1 tests/check_windows_powershell_compat.ps1
git commit -m "feat: export Jellyfin TV audit API state"
```

---

### Task 3: Add long-path-safe filesystem and NFO inventory

**Files:**
- Modify: `scripts/lib/tv_audit_common.ps1`
- Modify: `scripts/export_jellyfin_tv_audit_12.ps1`
- Modify: `tests/test_tv_audit_common.ps1`

**Interfaces:**
- Consumes each TV library `Locations` array.
- Produces `FilesystemVideos` rows with NFO summary/error fields.

- [ ] **Step 1: Add filesystem inventory tests**

Extend the helper test temp tree with a nested directory, one `.mkv`, one `.ass`, and a same-name `.nfo`. Verify only the video is returned and its NFO summary is attached:

```powershell
$mediaDir = Join-Path $tempRoot "nested"
New-Item -ItemType Directory -Path $mediaDir | Out-Null
$video = Join-Path $mediaDir "sample[02].mkv"
[System.IO.File]::WriteAllBytes($video, [byte[]](1,2,3,4))
$nfo = Join-Path $mediaDir "sample[02].nfo"
"<episodedetails><season>1</season><episode>2</episode><title>T</title></episodedetails>" | Set-Content -LiteralPath $nfo -Encoding UTF8
$subtitle = Join-Path $mediaDir "sample[02].ass"
"x" | Set-Content -LiteralPath $subtitle -Encoding ASCII

$files = @(Get-TvaVideoFiles -LibraryName "Test TV" -LibraryRoot $tempRoot)
Assert-Equal $files.Count 1 "video inventory count"
Assert-Equal $files[0].Length 4 "video length"
Assert-Equal $files[0].SameNameNfoExists $true "same-name NFO found"
Assert-Equal $files[0].NfoSummary.Episode 2 "inventory NFO episode"
```

- [ ] **Step 2: Add native Windows read-only filesystem support**

Implement `Initialize-TvaNativeFileSystem` with embedded C# and Windows Unicode APIs. The type must:

- convert drive/UNC paths to `\\?\` extended form internally;
- recursively enumerate with `FindFirstFileW` / `FindNextFileW`;
- skip `.` and `..`;
- skip directory reparse points to avoid loops;
- return file path, length, and last-write UTC/local-convertible timestamp;
- expose `FileExists(string path)`;
- expose read-only text loading for NFO through the extended path form.

The PowerShell wrapper `Get-TvaVideoFiles` filters enumeration results with `Test-TvaVideoExtension` and never mutates source files.

- [ ] **Step 3: Attach same-name NFO facts without making one bad NFO fatal**

For a video path `X.ext`, compute `X.nfo`. If present:

```powershell
try {
    $summary = Get-TvaNfoSummary -NfoPath $nfoPath
    $nfoError = ""
}
catch {
    $summary = $null
    $nfoError = $_.Exception.Message
}
```

The exported video row still exists when the NFO is malformed; this is an audit fact, not a reason to lose the video from the snapshot.

- [ ] **Step 4: Enumerate every TV location exactly once**

In the exporter, for every TV library and each non-empty location:

```powershell
$filesystemVideos += @(Get-TvaVideoFiles -LibraryName $library.Name -LibraryRoot ([string]$location))
```

Do not enumerate movie virtual-folder locations.

- [ ] **Step 5: Run helper/parser tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tv_audit_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

Expected: both PASS.

- [ ] **Step 6: Commit filesystem inventory**

```bash
git add scripts/lib/tv_audit_common.ps1 scripts/export_jellyfin_tv_audit_12.ps1 tests/test_tv_audit_common.ps1
git commit -m "feat: inventory TV filesystem for audit export"
```

---

### Task 4: Serialize atomically, document usage, and run real-server verification

**Files:**
- Modify: `scripts/export_jellyfin_tv_audit_12.ps1`
- Modify: `docs/library-export.md`
- Modify: `README.md`

**Interfaces:**
- Final command:

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

- Final top-level schema version: `1`.

- [ ] **Step 1: Build the final export object**

```powershell
$export = [ordered]@{
    SchemaVersion    = 1
    ExportedAt       = (Get-Date).ToString("o")
    Server           = [ordered]@{
        Version     = [string]$systemInfo.Version
        ProductName = [string]$systemInfo.ProductName
        ServerName  = [string]$systemInfo.ServerName
    }
    TvLibraries      = @($tvLibraries)
    NormalItems      = @($normalItems)
    ExpandedEpisodes = @($expandedEpisodes)
    FilesystemVideos = @($filesystemVideos)
}
```

- [ ] **Step 2: Write through a temporary sibling and replace the destination only after successful JSON conversion**

Use:

```powershell
$outputFull = [System.IO.Path]::GetFullPath($Output)
$outputDir = [System.IO.Path]::GetDirectoryName($outputFull)
if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
$tempOutput = $outputFull + ".tmp-" + [guid]::NewGuid().ToString("N")
$json = $export | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($tempOutput, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tempOutput -Destination $outputFull -Force
```

Wrap cleanup in `try/finally` so a failed run cannot leave a misleading final JSON.

- [ ] **Step 3: Add a secret-leak guard before final rename**

Before committing the temp file as final output:

```powershell
if ($json.Contains($ApiKey)) {
    throw "Refusing to write export because API key text appeared in serialized JSON."
}
```

- [ ] **Step 4: Document the dedicated audit command and boundaries**

In `docs/library-export.md`, add a section explaining:

- generic exporter vs TV audit exporter;
- TV-only scope;
- normal vs expanded Episode data;
- filesystem/NFO inventory;
- JSON contains local paths and metadata IDs;
- read-only Jellyfin behavior;
- movie libraries remain intentionally excluded.

In `README.md`, add one short link/command pointing to the dedicated TV audit exporter without replacing existing generic export documentation.

- [ ] **Step 5: Run all local tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_canonical_view_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tv_audit_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

Expected: all PASS.

- [ ] **Step 6: Run the exporter against the real Jellyfin 12 server**

Run:

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

Expected console summary includes:

```text
Mode: READ ONLY
TV libraries: <count>
Normal items: <count>
Expanded episodes: <count>
Filesystem videos: <count>
Output: ...\jellyfin-tv-audit-export.json
```

- [ ] **Step 7: Verify real output invariants before any metadata repair work**

Check the generated JSON and confirm:

```text
SchemaVersion == 1
TvLibraries all have CollectionType == tvshows
no movie-library path such as D:\Gekijouban appears
ExpandedEpisodes.Count >= normal Episode count
known hidden alternate Episodes are present in ExpandedEpisodes
known long Clevatess / Fujimoto-style paths appear in FilesystemVideos
Medalist / Fate / 100-girlfriends S3 records expose Name, ProviderIds, Overview, image tags and S/E fields
API key text is absent
```

Do not perform any Identify/Refresh action in this task even if the audit immediately reveals the likely cause.

- [ ] **Step 8: Commit docs/final exporter**

```bash
git add scripts/export_jellyfin_tv_audit_12.ps1 docs/library-export.md README.md
git commit -m "feat: add unified Jellyfin TV audit export"
```
