# Cross-Series Canonical Hardlink Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one final cross-series experiment that automatically selects a clean non-Medalist correction-target alternate group and tests whether a canonical `SxxEyy -` hardlink stays independent in Jellyfin 12.

**Architecture:** Reuse the read-only group discovery rules from `08-global-alternate-group-audit.ps1`, then reuse the remove/re-add observation pattern from scripts 12 and 13. The script changes only one selected non-owner member, keeps the real media payload in an out-of-library same-volume staging directory, creates a temporary canonical hardlink plus copied NFO, observes Jellyfin, and always attempts to restore the original path/group before exit.

**Tech Stack:** Windows PowerShell 5.1-compatible script, Jellyfin 12 HTTP API, NTFS hard links, existing correction run log.

## Global Constraints

- Default mode is dry-run; `-Apply` is required for file changes.
- Only `jellyfin_tv_nfo_run_log.csv` correction targets are eligible.
- Exclude Medalist SeriesId `1e343af25a95b525ae23adc50142693a`.
- Require every source in the chosen group to map uniquely to a correction target and every expected S/E in the group to be distinct.
- Prefer groups outside `2026-01`, then smaller groups.
- Do not write SQLite, call metadata FullRefresh, call `/Videos/{id}/AlternateSources`, or modify NFO XML.
- Staging must be outside Jellyfin library roots and on the same volume as the selected media.
- After observation, delete the temporary canonical hardlink/NFO and restore the original video/NFO path.

---

### Task 1: Implement candidate discovery and preflight

**Files:**
- Create: `experiments/jellyfin12-nfo-refresh/14-cross-series-canonical-hardlink-pilot.ps1`

**Interfaces:**
- Consumes: Jellyfin `/Items`, `/Library/VirtualFolders`, `/System/Info`; `jellyfin_tv_nfo_run_log.csv`.
- Produces: one selected group and one selected hidden non-owner correction target with original path, expected S/E, owner ID/count, SeriesId, NFO path, canonical path, and staging path.

- [ ] Parse correction targets and reject conflicting duplicate path targets.
- [ ] Load normal Episodes with `MediaSources` and expanded Episodes with `VideoTypes=VideoFile`.
- [ ] Build only clean groups where every source is a known target, expected keys are all distinct, current expanded keys equal expected keys, and a hidden non-owner target exists.
- [ ] Sort candidates by `2026-01` penalty, then source count, then series/path for deterministic selection.
- [ ] Validate source video/NFO, library realtime monitor, canonical path absence, same-volume staging, and staging outside all library roots.
- [ ] Print the complete dry-run candidate and planned canonical/staging paths.

### Task 2: Implement apply observation and guaranteed restoration

**Files:**
- Modify: `experiments/jellyfin12-nfo-refresh/14-cross-series-canonical-hardlink-pilot.ps1`

**Interfaces:**
- Consumes: Task 1 candidate/preflight state.
- Produces: one of `CANONICAL HARDLINK STAYS INDEPENDENT`, `CANONICAL HARDLINK RE-MERGED`, `PARTIAL / OTHER STATE`, followed by restoration status.

- [ ] Move original NFO/video to staging and wait until owner count decreases by one and original path disappears.
- [ ] Copy staged NFO to canonical basename and create an NTFS hardlink from canonical video path to staged video.
- [ ] Poll canonical path until stable and classify independent/remerged/other using normal visibility, expanded visibility, expected key, media-source count, SeriesId, Series visibility, and owner membership.
- [ ] Remove canonical NFO/hardlink and wait until Jellyfin forgets the canonical path.
- [ ] Move staged NFO/video back to their exact original paths and wait for the original alternate group to return.
- [ ] Abort further mutation on failed safety preconditions; on exceptions, prioritize restoring original files and report any incomplete Jellyfin-state restoration.

### Task 3: Verify and document run instructions

**Files:**
- Modify: `experiments/jellyfin12-nfo-refresh/README.md`

**Interfaces:**
- Consumes: completed script.
- Produces: documented dry-run/apply commands and success criteria.

- [ ] Parse the PowerShell file with a local PowerShell parser if available; otherwise re-fetch and inspect the committed source and state that runtime verification requires the user's Jellyfin environment.
- [ ] Add `14-cross-series-canonical-hardlink-pilot.ps1` to the experiment table as the final cross-series validation before the 243-target view generator.
- [ ] Document that the script restores original paths after the observation and that the user should run dry-run first.
- [ ] Commit the script and documentation.