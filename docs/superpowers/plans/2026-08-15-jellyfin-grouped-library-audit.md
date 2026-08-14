# Jellyfin Grouped Library & Series Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two Python tools: one clones a configured TV library into the nine `View-v3` year/quarter groups, and one performs a read-only Series identity audit for those groups.

**Architecture:** Reuse path normalization and Jellyfin GET helpers from `scripts/build_jellyfin_full_canonical_view.py`. Keep all Jellyfin mutation isolated in the grouped-library creator behind `--apply`; the audit script remains GET-only. Library creation copies the template `LibraryOptions`, changes only the target path, creates missing libraries, and triggers one final `/Library/Refresh`.

**Tech Stack:** Python 3 standard library, Jellyfin 12 HTTP API, existing `build_jellyfin_full_canonical_view.py` helpers.

## Global Constraints

- Do not modify `View-v3`, original media, NFO files, or the Jellyfin SQLite database directly.
- Do not delete or rename existing Jellyfin libraries.
- Do not touch `C:\bangumi`.
- `create_jellyfin_grouped_libraries.py` is dry-run by default; writes require `--apply`.
- `audit_jellyfin_series_identity.py` is always read-only.
- Target grouped libraries are the direct child directories under `D:\Resource\BangumiLink\View-v3`.
- Template library must be `CollectionType=tvshows`.

---

### Task 1: Grouped-library plan and safety logic

**Files:**
- Create: `tests/test_create_jellyfin_grouped_libraries.py`
- Create: `scripts/create_jellyfin_grouped_libraries.py`

**Interfaces:**
- Produces `discover_targets(view_root) -> list[dict]`.
- Produces `clone_library_options(template_options, target_path) -> dict`.
- Produces `build_plan(targets, virtual_folders) -> list[dict]` with `CREATE` or `SKIP` states and raises on name/path conflicts.

- [ ] Write unit tests first for template option copying, exact same-name/same-path idempotency, same-name/different-path conflict, and same-path/different-name conflict.
- [ ] Run tests and confirm they fail because the module is absent.
- [ ] Implement only the pure planning helpers.
- [ ] Run tests and confirm planning tests pass.

### Task 2: Jellyfin grouped-library apply path

**Files:**
- Modify: `scripts/create_jellyfin_grouped_libraries.py`
- Modify: `tests/test_create_jellyfin_grouped_libraries.py`

**Interfaces:**
- `jellyfin_request(server, api_key, method, path, query=None, body=None)` uses the existing MediaBrowser authorization format.
- `apply_plan(...)` creates only `CREATE` rows through `POST /Library/VirtualFolders` and then calls `POST /Library/Refresh` once if at least one library was created.

- [ ] Add tests around generated request query/body using an injected request function; assert the template path is not retained and refresh is called once.
- [ ] Confirm new tests fail before implementation.
- [ ] Implement CLI, template lookup, dry-run printing, `--apply`, creation, and one final refresh.
- [ ] Confirm all grouped-library tests pass.

### Task 3: Series identity audit

**Files:**
- Create: `tests/test_audit_jellyfin_series_identity.py`
- Create: `scripts/audit_jellyfin_series_identity.py`

**Interfaces:**
- `classify_series(item) -> str` returns `OK`, `NO_TVDB_ID`, `NO_PRIMARY_IMAGE`, or `NO_TVDB_AND_IMAGE`.
- `choose_library(series_path, library_roots) -> dict | None` chooses the most specific matching grouped-library root so a broad template library does not duplicate rows.
- `build_rows(series_items, episode_items, library_roots, view_root) -> list[dict]` produces the CSV-ready audit rows.

- [ ] Write tests first for status classification, most-specific library selection, Episode counting, and filtering outside `View-v3`.
- [ ] Confirm tests fail because the module is absent.
- [ ] Implement paged GET queries for Series and Episodes, mapping to the most-specific TV library, console summary, anomaly list, and optional CSV output.
- [ ] Confirm audit tests pass.

### Task 4: Verification

**Files:**
- No new production files.

- [ ] Run `python -m unittest tests.test_create_jellyfin_grouped_libraries tests.test_audit_jellyfin_series_identity -v`.
- [ ] Run `python -m py_compile scripts/create_jellyfin_grouped_libraries.py scripts/audit_jellyfin_series_identity.py`.
- [ ] Inspect both scripts for accidental API-key output and verify the audit script contains no POST/DELETE/PUT/PATCH request path.
- [ ] Re-read the design and confirm no automatic Identify, no library deletion, no `C:\bangumi`, and no file/NFO mutation were added.
