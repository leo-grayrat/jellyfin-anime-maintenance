# Jellyfin Canonical View Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows PowerShell 5.1-compatible tool that preflights and, with `-Apply`, creates a 243-target Jellyfin canonical view under `D:\Resource\BangumiLink` without modifying or moving source media.

**Architecture:** Keep filesystem- and data-oriented helpers in a small dot-sourced library so target parsing, NFO validation, canonical path mapping, manifest checks, and native hardlink creation can be tested independently. The command script owns Jellyfin API discovery, all-or-nothing preflight, dry-run output, Apply orchestration, rollback of files created by the current build, and persistent manifest/build logs.

**Tech Stack:** Windows PowerShell 5.1, Jellyfin 12 HTTP API, CSV, XML, NTFS hardlinks via `CreateHardLinkW`.

## Global Constraints

- Default root is exactly `D:\Resource\BangumiLink` with `View`, `Temp`, and `Logs` children.
- New staging/probe/build temporary directories must not be created directly under `D:\`.
- First version processes exactly 243 correction targets from `jellyfin_tv_nfo_run_log.csv`; it does not scan or mirror the whole TV library.
- Dry-run is read-only and must not create `View`, `Temp`, or `Logs` content.
- `-Apply` is required for filesystem writes.
- Source media and source NFO files must never be renamed, moved, overwritten, or deleted.
- Canonical video names are `SxxEyy - <original filename>` and are created with native Windows `CreateHardLinkW`, not `New-Item -ItemType HardLink`.
- Canonical NFO files are copied, not hardlinked, and XML content is not modified.
- View paths preserve each source file's relative directory below its unique Jellyfin library root.
- Existing unmanaged target files are never overwritten.
- Unknown alternate-group members and normal library files outside the 243 correction targets are out of scope.
- The script must remain compatible with Windows PowerShell 5.1.

---

### Task 1: Pure canonical-view helpers and regression tests

**Files:**
- Create: `scripts/lib/canonical_view_common.ps1`
- Create: `tests/test_canonical_view_common.ps1`
- Modify: `tests/check_windows_powershell_compat.ps1`

**Interfaces:**
- Consumes: correction CSV rows, source paths, library root/name, NFO XML, existing manifest rows.
- Produces: `Get-CvPathKey`, `Get-CvEpisodeKey`, `Get-CvCorrectionTargets`, `Get-CvNfoIdentity`, `Get-CvRelativeDirectory`, `Get-CvCanonicalPaths`, `Get-CvManifestIndex`, `Test-CvExistingTarget`, `Initialize-CvNativeHardLink`, `New-CvNativeHardLink`.

- [ ] **Step 1: Write the failing helper test**

Create `tests/test_canonical_view_common.ps1` with fixture-only tests that do not call Jellyfin or touch user media. It must verify at minimum:

```powershell
. "$PSScriptRoot\..\scripts\lib\canonical_view_common.ps1"

Assert-Equal (Get-CvEpisodeKey -Season 1 -Episode 2) "S01E02" "episode key"

$relative = Get-CvRelativeDirectory `
    -SourceDirectory 'D:\Bangumi\2026\2026-07\Work A' `
    -LibraryRoot 'D:\Bangumi\2026\2026-07'
Assert-Equal $relative 'Work A' "relative directory"

$paths = Get-CvCanonicalPaths `
    -ViewRoot 'D:\Resource\BangumiLink\View' `
    -LibraryName '2026-07' `
    -RelativeDirectory 'Work A' `
    -VideoPath 'D:\Bangumi\2026\2026-07\Work A\[Group] Show [02].mkv' `
    -NfoPath 'D:\Bangumi\2026\2026-07\Work A\[Group] Show [02].nfo' `
    -ExpectedKey 'S01E02'
Assert-Equal $paths.Video 'D:\Resource\BangumiLink\View\2026-07\Work A\S01E02 - [Group] Show [02].mkv' "canonical video path"
Assert-Equal $paths.Nfo 'D:\Resource\BangumiLink\View\2026-07\Work A\S01E02 - [Group] Show [02].nfo' "canonical nfo path"
```

Also create temporary fixture CSV/NFO files below `$env:TEMP` and assert:

- duplicate CSV rows for the same path with the same S/E collapse to one target;
- conflicting S/E for the same path throws;
- a non-243 fixture can be parsed when the helper receives an explicit expected count for tests;
- `<season>` / `<episode>` are read correctly;
- malformed/missing NFO identity throws;
- manifest-owned same-source paths are reusable;
- unmanaged existing paths are classified as conflicts.

- [ ] **Step 2: Run the helper test and verify RED**

Run on Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_canonical_view_common.ps1
```

Expected: FAIL because `scripts/lib/canonical_view_common.ps1` does not exist yet.

- [ ] **Step 3: Implement the minimal helper library**

Create ASCII-only `scripts/lib/canonical_view_common.ps1` implementing the exact interfaces above. Important behavior:

```powershell
function Get-CvEpisodeKey {
    param([int]$Season, [int]$Episode)
    return "S{0:D2}E{1:D2}" -f $Season, $Episode
}
```

`Get-CvCorrectionTargets` must filter `RuleId -ne 'series-nfo'`, `Action -eq 'WRITE'`, require `VideoPath/Season/Episode`, normalize paths, collapse identical duplicates, reject conflicting duplicates, and enforce `ExpectedCount` (default 243).

`Get-CvNfoIdentity` must parse XML with `Get-Content -LiteralPath -Raw`, require `<season>` and `<episode>`, and return integer values.

`Get-CvRelativeDirectory` must prove the source directory is inside the library root and return the relative directory without using APIs unavailable in Windows PowerShell 5.1.

`Get-CvCanonicalPaths` must preserve the relative directory under `View\<LibraryName>` and prefix only the video/NFO basenames with `SxxEyy - `.

`Initialize-CvNativeHardLink` / `New-CvNativeHardLink` must call `Kernel32!CreateHardLinkW`, use literal filesystem checks, verify same drive root, verify destination absence, and verify the created link exists and matches source length.

- [ ] **Step 4: Run helper tests and compatibility parser**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_canonical_view_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

Expected: both PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add scripts/lib/canonical_view_common.ps1 tests/test_canonical_view_common.ps1 tests/check_windows_powershell_compat.ps1
git commit -m "test: add canonical view core helpers"
```

### Task 2: Read-only planning and all-or-nothing preflight

**Files:**
- Create: `scripts/build_jellyfin_canonical_view.ps1`
- Modify: `tests/check_windows_powershell_compat.ps1`

**Interfaces:**
- Consumes: `-ApiKey`, `-Server`, `-RunLogPath`, optional `-Root` defaulting to `D:\Resource\BangumiLink`, helper library from Task 1.
- Produces: a 243-row in-memory build plan and dry-run summary; no persistent files in dry-run.

- [ ] **Step 1: Write the failing command-shape regression test**

Extend `tests/test_canonical_view_common.ps1` with source-level assertions that `scripts/build_jellyfin_canonical_view.ps1` exists and contains these exact safety surfaces:

```text
[string]$Root = "D:\Resource\BangumiLink"
[switch]$Apply
$ExpectedTargetCount = 243
/Library/VirtualFolders
```

Also assert it does not contain `_jellyfin_repair_staging` or `New-Item -ItemType HardLink`.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL because the command script does not exist.

- [ ] **Step 3: Implement dry-run/preflight command**

The command must:

1. dot-source `scripts/lib/canonical_view_common.ps1`;
2. authenticate with the same Jellyfin API-key Authorization shape used by the existing Jellyfin 12 scripts;
3. fetch `/System/Info` and `/Library/VirtualFolders`;
4. parse exactly 243 correction targets;
5. for every target, require source video and same-basename NFO to exist;
6. parse NFO and require NFO S/E to equal correction target S/E;
7. find exactly one containing Jellyfin library location by longest path-safe containment logic;
8. derive the source directory relative to that exact library root;
9. generate canonical paths under `Root\View\<LibraryName>\<relative source directory>`;
10. reject duplicate canonical target paths;
11. read `Root\Logs\manifest.csv` only if it already exists; dry-run must not create it;
12. classify existing canonical files as reusable only when manifest proves the same source; otherwise fail preflight;
13. require source and target to share the same drive root;
14. print counts for planned/reusable/to-create/conflicts and a few sample mappings;
15. if any preflight failure exists, exit before any write even when `-Apply` was supplied.

- [ ] **Step 4: Run parser/tests**

Run the same two test commands from Task 1. Expected: PASS.

- [ ] **Step 5: Runtime dry-run on the real server**

Run:

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

Expected before Apply:

```text
Mode: DRY RUN
Correction targets: 243
Preflight failures: 0
Planned targets: 243
No files were written.
```

This is the first real-library verification gate; do not proceed to Apply logic if it fails.

- [ ] **Step 6: Commit Task 2**

```bash
git add scripts/build_jellyfin_canonical_view.ps1 tests/check_windows_powershell_compat.ps1 tests/test_canonical_view_common.ps1
git commit -m "feat: add canonical view preflight"
```

### Task 3: Apply, rollback, manifest, and build logs

**Files:**
- Modify: `scripts/build_jellyfin_canonical_view.ps1`
- Modify: `tests/test_canonical_view_common.ps1`

**Interfaces:**
- Consumes: fully validated 243-row build plan from Task 2.
- Produces: canonical hardlinks/NFO copies under `View`, `Logs\manifest.csv`, `Logs\build-<timestamp>.csv`, temporary plan state under `Temp\build-<timestamp>` during Apply only.

- [ ] **Step 1: Add failing state/rollback tests**

Extend helper tests with temporary fixture directories that exercise manifest-index and rollback bookkeeping without Jellyfin:

- current-build-created files are recorded distinctly from reusable files;
- rollback candidate list contains only files created by the current build;
- an existing manifest-owned same-source target is not added to rollback;
- manifest merge replaces rows by canonical video path and does not duplicate records.

- [ ] **Step 2: Run tests and verify RED**

Expected: FAIL until state helper functions are added.

- [ ] **Step 3: Add minimal state helpers and Apply orchestration**

Add helper functions as needed for deterministic manifest merge and current-build rollback lists. In the command script, `-Apply` must:

1. create `Root`, `View`, `Temp`, and `Logs` only after global preflight is clean;
2. create `Temp\build-<timestamp>` and write an apply plan CSV there;
3. create required View directories;
4. create each missing video with `New-CvNativeHardLink`;
5. copy each NFO with `Copy-Item -LiteralPath` to the canonical basename;
6. verify canonical video existence/length and canonical NFO existence;
7. record whether each item was `CREATED`, `REUSED`, or failed;
8. on any failure, stop immediately and remove only files/directories created by the current build, leaving prior manifest-managed files untouched;
9. on success, atomically replace `Logs\manifest.csv` via a temp file in `Temp\build-<timestamp>` followed by move;
10. write `Logs\build-<timestamp>.csv` with per-target results;
11. remove the temporary build directory only after manifest/log finalization succeeds;
12. print the success counters from the spec and explicitly state that source media modified/moved counts are zero.

Do not call Jellyfin metadata refresh or change Jellyfin library paths.

- [ ] **Step 4: Run tests and compatibility parser**

Expected: PASS.

- [ ] **Step 5: Real-server dry-run after Apply code exists**

Run the normal command without `-Apply` again. Expected: still read-only and preflight clean.

- [ ] **Step 6: Real-server Apply and idempotency verification**

Run:

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>" -Apply
```

Expected:

```text
planned targets = 243
preflight failures = 0
canonical videos ready = 243
canonical NFOs ready = 243
source media modified = 0
source media moved = 0
unmanaged target overwritten = 0
manifest ready = true
build log ready = true
```

Then run dry-run again and confirm all 243 canonical files are classified as reusable with no new conflicts.

- [ ] **Step 7: Commit Task 3**

```bash
git add scripts/build_jellyfin_canonical_view.ps1 scripts/lib/canonical_view_common.ps1 tests/test_canonical_view_common.ps1
git commit -m "feat: build 243-target canonical view"
```

### Task 4: User-facing documentation and experiment-history closure

**Files:**
- Create: `docs/canonical-view.md`
- Modify: `README.md`
- Modify: `experiments/jellyfin12-nfo-refresh/README.md`

**Interfaces:**
- Consumes: final command behavior and verified runtime output.
- Produces: concise operating instructions and a clear statement that the single-item experiment phase is closed.

- [ ] **Step 1: Write documentation after runtime behavior is known**

`docs/canonical-view.md` must explain in Chinese:

- why NFO remains the metadata source but is no longer the complete Jellyfin repair mechanism;
- `D:\Resource\BangumiLink\View|Temp|Logs` layout;
- dry-run and Apply commands;
- that first version contains only the 243 correction targets and must not yet replace the whole Jellyfin TV library;
- manifest purpose and idempotent reruns;
- rollback boundaries and the fact that original media is not moved/renamed.

Update the experiment README to mark experiments 14-16 and the cross-series native-hardlink validation with their actual outcomes, and state that no more single-item experiments are planned before the 243-target builder.

- [ ] **Step 2: Run final compatibility/tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_canonical_view_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

Expected: PASS.

- [ ] **Step 3: Commit documentation**

```bash
git add docs/canonical-view.md README.md experiments/jellyfin12-nfo-refresh/README.md
git commit -m "docs: document canonical view workflow"
```
