# Full Canonical View Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows PowerShell 5.1-compatible full TV canonical-view builder that mirrors every production TV file, renames only the 243 confirmed correction targets and their exact-stem sidecars, and preserves all other files unchanged.

**Architecture:** Freeze the validated Phase 1 builder. Add `full_canonical_view_common.ps1` for pure full-view planning, source inventory, sidecar ownership, per-file roles/operations, manifest-v2 checks, and reusable-target classification. Add `build_jellyfin_full_canonical_view.ps1` as the orchestration layer: discover only production TV roots under `D:\Bangumi`, enumerate them with the existing native long-path audit helper, validate the 243 correction targets and Phase 1 manifest, perform an all-or-nothing dry-run preflight, then optionally build/reuse the full View with native hardlinks/copies and rollback only current-build files.

**Tech Stack:** Windows PowerShell 5.1, Jellyfin 12 HTTP API, CSV/XML, existing `TvaNativeFileSystem` long-path enumeration, existing `CvNativeFileSystem` hardlink/copy/delete helpers.

## Global Constraints

- Work on `feat/tv-audit-export`; do not implement on `main`.
- Preserve the README content already synchronized from `main`.
- Source media remain untouched: no rename, move, overwrite, delete, or SQLite writes.
- Default work root remains exactly `D:\Resource\BangumiLink` with `View`, `Temp`, and `Logs` children.
- Production TV source scope defaults to `D:\Bangumi`; `C:\bangumi`, `D:\Jellyfin-Repro`, and `D:\Gekijouban` must not enter the production plan.
- Expected production video count is exactly 676 and expected correction-target count is exactly 243 until a separately validated baseline changes these values.
- Only the 243 correction targets receive `SxxEyy - ` prefixes; all other source files retain their relative directory and filename.
- A correction sidecar is a non-video file in the same directory whose file stem exactly equals the target video's file stem.
- Correction source videos and correction sidecars are excluded from passthrough planning.
- If a sidecar can map to more than one correction target, preflight fails.
- Videos and clearly read-only subtitle sidecars (`.ass`, `.ssa`, `.srt`, `.vtt`, `.sub`, `.idx`) use hardlinks; `.nfo` and all other non-video files default to copy.
- Unknown files are preserved, not silently dropped.
- Source roots and View root must not contain one another.
- Existing unmanaged View paths are conflicts and are never overwritten.
- Phase 1 `Logs\manifest.csv` remains unchanged and is used only as source proof for existing 243 target video/NFO paths.
- Phase 2 uses `Logs\full-manifest-v2.csv`; it does not repurpose the Phase 1 manifest.
- Dry-run performs no filesystem writes.
- Apply does not switch Jellyfin production library roots automatically.
- New/modified `.ps1` sources must remain ASCII-only and parse under Windows PowerShell 5.1.

---

### Task 1: Full-view planning helper contracts

**Files:**
- Create: `tests/test_full_canonical_view_common.ps1`
- Create: `scripts/lib/full_canonical_view_common.ps1`
- Modify: `tests/check_windows_powershell_compat.ps1`

**Interfaces:**
- Consumes: source-file rows (`LibraryName`, `LibraryRoot`, `Path`, `Length`), correction target rows from `Get-CvCorrectionTargets`, existing Phase 1/Phase 2 manifest rows.
- Produces: `Get-FcvPathExtension`, `Test-FcvVideoPath`, `Get-FcvFileStem`, `Get-FcvSourceFiles`, `Assert-FcvDisjointRoots`, `Get-FcvTargetIndex`, `Get-FcvTargetForSidecar`, `Get-FcvOperation`, `Get-FcvCanonicalPath`, `New-FcvPlan`, `Get-FcvManifestIndex`, `Test-FcvExistingTarget`, `Merge-FcvManifestRows`, `Get-FcvRollbackPaths`.

- [ ] **Step 1: Add a failing fixture-only test before the helper exists**

The test must dot-source `canonical_view_common.ps1`, `tv_audit_common.ps1`, and the not-yet-created `full_canonical_view_common.ps1`, then create only files below `$env:TEMP`.

It must verify these exact behaviors:

```powershell
Assert-Equal (Get-FcvFileStem -Path 'D:\TV\Show\ep01.mkv') 'ep01' 'video stem'
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.mkv' -IsVideo $true) 'HARDLINK' 'video hardlink'
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.ass' -IsVideo $false) 'HARDLINK' 'subtitle hardlink'
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\ep01.nfo' -IsVideo $false) 'COPY' 'nfo copy'
Assert-Equal (Get-FcvOperation -Path 'D:\TV\Show\poster.jpg' -IsVideo $false) 'COPY' 'unknown metadata copy'
```

Fixture plan assertions must prove:

- one correction video maps to `S01E02 - original.mkv` and role `CORRECTION_VIDEO`;
- exact-stem `.ass` and `.nfo` map to the same prefix and role `CORRECTION_SIDECAR`;
- a non-target video retains its original filename and role `PASSTHROUGH_VIDEO`;
- unrelated files retain their original filename and role `PASSTHROUGH_FILE`;
- target video/sidecars appear exactly once, never also as passthrough;
- canonical path collisions throw;
- a sidecar ambiguous between two correction targets throws;
- View-inside-source and source-inside-View both throw;
- Phase 2 manifest-owned same-source/same-length target is reusable;
- unmanaged existing target is conflict;
- rollback paths include only rows created by the current build.

- [ ] **Step 2: Verify RED on Windows PowerShell 5.1**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_common.ps1
```

Expected before implementation: FAIL because `scripts\lib\full_canonical_view_common.ps1` does not exist.

- [ ] **Step 3: Implement the minimal helper**

`Get-FcvSourceFiles` must call `Initialize-TvaNativeFileSystem` and `[TvaNativeFileSystem]::EnumerateFilesRecursive($LibraryRoot)`; do not add another embedded C# filesystem implementation.

`New-FcvPlan` must return one row per source file with exactly these fields:

```text
SourcePath
CanonicalPath
LibraryName
LibraryRoot
RelativePath
Role
Operation
SourceLength
ExpectedKey
State
```

It must build the correction target index by normalized source path, build a sidecar ownership index by same directory + exact stem, exclude owned correction paths from passthrough, then add passthrough rows for every remaining source file. It must fail on duplicate source ownership or canonical path collision.

- [ ] **Step 4: Extend the PowerShell 5.1 compatibility test**

Add these paths to `tests/check_windows_powershell_compat.ps1`:

```text
scripts/lib/full_canonical_view_common.ps1
scripts/build_jellyfin_full_canonical_view.ps1
```

The command script does not exist yet, so this compatibility test is expected to remain RED until Task 2.

- [ ] **Step 5: Commit Task 1**

Commit test/helper changes separately from the command script.

---

### Task 2: Read-only full-view command and all-or-nothing preflight

**Files:**
- Create: `tests/test_full_canonical_view_command.ps1`
- Create: `scripts/build_jellyfin_full_canonical_view.ps1`

**Interfaces:**
- Parameters: `-ApiKey <string>` mandatory, `-Server 'http://127.0.0.1:8096'`, `-RunLogPath '.\jellyfin_tv_nfo_run_log.csv'`, `-Root 'D:\Resource\BangumiLink'`, `-ProductionRoot 'D:\Bangumi'`, `-ExpectedVideoCount 676`, `-ExpectedTargetCount 243`, `-Apply`.
- Reads Jellyfin `/System/Info` and `/Library/VirtualFolders` with GET only.
- Writes nothing unless `-Apply` is supplied and every preflight check passes.

- [ ] **Step 1: Write the command safety test first**

The test reads the script source and asserts:

- required defaults `D:\Bangumi`, `676`, `243`, and `D:\Resource\BangumiLink` exist;
- it dot-sources all three helpers;
- it contains only Jellyfin GET calls;
- it does not contain SQLite mutation, `New-Item -ItemType HardLink`, source `Move-Item`, or source `Remove-Item` operations;
- it references `full-manifest-v2.csv` and does not replace Phase 1 `manifest.csv`;
- it has a `DRY RUN` early exit before any `New-CvNativeDirectoryTree`, hardlink, copy, manifest or log write;
- it does not mutate Jellyfin library configuration.

- [ ] **Step 2: Verify RED**

Run on Windows PowerShell 5.1; expected FAIL because the command script does not exist.

- [ ] **Step 3: Implement source discovery and preflight**

The command must:

1. GET server info and virtual folders.
2. Keep only `CollectionType=tvshows` locations whose normalized root equals or is below `D:\Bangumi`.
3. Fail if no production location is found or if a selected source root is under View / contains View.
4. Enumerate every file under selected roots with `Get-FcvSourceFiles`.
5. Count video files with `Test-FcvVideoPath`; require exactly 676.
6. Load exactly 243 correction targets with `Get-CvCorrectionTargets`.
7. Prove each target exists in the production source-video set.
8. Prove each target same-name NFO exists and has matching S/E via `Get-CvNfoIdentity`.
9. Read Phase 1 `Logs\manifest.csv` if present and validate all existing correction video/NFO targets it claims.
10. Read Phase 2 `Logs\full-manifest-v2.csv` if present.
11. Call `New-FcvPlan`, classify each planned path as `MISSING`, `REUSABLE`, or `CONFLICT`, and fail if any conflict exists.
12. Print counts for source files, source videos, correction videos, correction sidecars, passthrough videos/files, hardlinks, copies, reusable files, files to create, and failures.
13. In dry-run, exit without creating `View`, `Temp`, or `Logs` content.

- [ ] **Step 4: Commit Task 2**

Commit the read-only command and safety test.

---

### Task 3: Apply, manifest v2, rollback, and idempotency

**Files:**
- Modify: `tests/test_full_canonical_view_common.ps1`
- Modify: `tests/test_full_canonical_view_command.ps1`
- Modify: `scripts/lib/full_canonical_view_common.ps1`
- Modify: `scripts/build_jellyfin_full_canonical_view.ps1`

**Interfaces:**
- Phase 2 manifest path: `D:\Resource\BangumiLink\Logs\full-manifest-v2.csv` by default.
- Build temp: `Temp\full-build-<timestamp>`.
- Build log: `Logs\full-build-<timestamp>.csv`.
- Manifest rows expose exactly: `SourcePath`, `CanonicalPath`, `LibraryName`, `Role`, `Operation`, `SourceLength`, `ExpectedKey`, `BuildId`, `Status`.

- [ ] **Step 1: Extend tests before Apply implementation**

Tests must verify:

- hardlink plan rows call the existing `New-CvNativeHardLink` helper;
- copy plan rows call `Copy-CvNativeFile` without overwriting unmanaged files;
- manifest merge is keyed by canonical path and rejects duplicate canonical ownership;
- only current-build `CREATED` rows are returned for rollback;
- source paths are never returned as rollback paths;
- command source contains rollback handling and atomic manifest replacement with temp file + `Move-CvNativeFileReplace`;
- command never deletes old manifest before a replacement manifest is ready.

- [ ] **Step 2: Implement Apply**

After a second full preflight in the same invocation:

1. Create Root/View/Temp/Logs/full-build directories using existing native directory helpers.
2. Persist the exact preflight plan in build temp.
3. For each row: create its parent directory, then either reuse, hardlink, or copy according to plan.
4. After creation verify destination exists and its length equals `SourceLength`.
5. Append a build row with `CREATED` or `REUSED` status.
6. Build the merged manifest-v2 from previous managed rows plus successful current rows.
7. Write manifest temp and build-log temp, then atomically replace final files with `Move-CvNativeFileReplace`.
8. If any file operation fails, stop immediately; delete only current-build created View files, then remove only current-build empty View directories in reverse depth order.
9. Preserve temp/failure log when rollback has any error.

- [ ] **Step 3: Verify idempotency contract**

A second dry-run against an Apply-built fixture must classify every managed path as `REUSABLE` and plan zero creates. This is a fixture-level test; real production validation remains a user-run gate.

- [ ] **Step 4: Commit Task 3**

Commit Apply/rollback/manifest changes.

---

### Task 4: Documentation and real Windows validation handoff

**Files:**
- Modify: `docs/canonical-view.md`
- Modify: `README.md` only by adding Phase 2 usage while preserving the existing user-authored opening text.
- Modify: issue #4 with implementation evidence after commits exist.

**Interfaces:**
- Dry-run command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\build_jellyfin_full_canonical_view.ps1 `
    -ApiKey "<API_KEY>"
```

- Apply is not requested until dry-run output is reviewed.

- [ ] **Step 1: Document Phase 1 vs Phase 2 clearly**

State that Phase 1 remains the frozen 243-target builder. Phase 2 mirrors all production TV files, renames only confirmed targets and exact-stem sidecars, and is not yet permission to switch the production Jellyfin library.

- [ ] **Step 2: Preserve README user edits**

Before updating README, fetch current branch README and retain its opening heading/commentary verbatim. Add only a concise Full View subsection under usage.

- [ ] **Step 3: Run/hand off verification**

Required Windows commands before any production Apply:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_command.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_jellyfin_full_canonical_view.ps1 -ApiKey "<API_KEY>"
```

Expected: all tests PASS and dry-run reports 676 production videos, 243 correction targets, zero conflicts/failures. Do not claim these runtime results until they are observed on the user's Windows PowerShell 5.1 machine.

- [ ] **Step 4: Update issue #4**

Record implemented commit SHAs, exact safety boundaries, and distinguish repository implementation from still-pending real Windows dry-run/Apply/production-switch validation.
