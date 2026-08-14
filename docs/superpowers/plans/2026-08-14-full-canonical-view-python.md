# Full Canonical View Python Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unfinished PowerShell Phase 2 with a Python read-only inventory/mapping dry-run that explains the 634-vs-676 discrepancy before any Apply logic exists.

**Architecture:** One Python script owns Jellyfin GET, filesystem inventory, target loading, mapping, and set-diff reporting. One unittest file covers pure path/target/mapping behavior. Standard library only.

**Tech Stack:** Python 3 standard library (`argparse`, `csv`, `json`, `ntpath`, `os`, `urllib.request`, `unittest`).

## Global Constraints

- No `--apply` in this milestone.
- No View/Temp/Logs writes.
- Jellyfin requests are GET only.
- Keep the established video extensions: `.mkv`, `.mp4`, `.m4v`, `.avi`, `.ts`, `.webm`.
- Exclude test roots and `D:\Gekijouban`; do not modify old validated PowerShell tools.
- 243 correction targets are loaded from the existing run log; no new S/E inference.

---

### Task 1: Pure Python mapping core

**Files:**
- Create: `scripts/build_jellyfin_full_canonical_view.py`
- Create: `tests/test_full_canonical_view.py`

**Interfaces:**
- `path_key(path: str) -> str`
- `is_video(path: str) -> bool`
- `load_targets(csv_path: str, expected_count: int) -> list[dict]`
- `build_mapping(files, targets, view_root) -> list[dict]`

- [ ] Write unittest fixtures for path normalization, target rename, same-stem sidecar rename, passthrough, duplicate/conflicting targets, and canonical collisions.
- [ ] Run `python -m unittest tests.test_full_canonical_view -v` and verify RED.
- [ ] Implement only the pure functions needed by those tests.
- [ ] Run the same command and verify GREEN.

### Task 2: Read-only Jellyfin/filesystem inventory and 676 diff

**Files:**
- Modify: `scripts/build_jellyfin_full_canonical_view.py`
- Modify: `tests/test_full_canonical_view.py`

**Interfaces:**
- `jellyfin_get(server, api_key, path, query=None)`
- `get_tv_libraries(...)`
- `get_expanded_episode_paths(...)`
- `enumerate_files(roots)`
- CLI output with per-root/per-extension counts and `JELLYFIN_ONLY` / `FILESYSTEM_ONLY` sections.

- [ ] Add fixture tests for virtual-folder filtering and set-diff reporting.
- [ ] Implement GET-only API client and pagination matching the validated TV audit query (`IncludeItemTypes=Episode`, `VideoTypes=VideoFile`).
- [ ] Enumerate every selected production TV library location instead of assuming one `D:\Bangumi` root.
- [ ] Print selected roots before counting files so a missing root is immediately visible.
- [ ] Print filesystem video count, Jellyfin expanded Episode path count, and both set differences. Do not fail merely because the count is not 676; fail only on malformed/ambiguous input.
- [ ] Run local unittests.
- [ ] Commit and ask for one real Windows dry-run; do not add Apply until its output explains the baseline.
