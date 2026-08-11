# Jellyfin Library Export Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two read-only PowerShell exporters for Jellyfin 10.x and 12.x so users or AI can quickly inspect local library metadata as JSON.

**Architecture:** Keep version-specific authentication in two small scripts while keeping the exported data shape identical. Both scripts accept the API key as a mandatory parameter, fail immediately on API errors, and never write to Jellyfin. A short Chinese document explains which script to use and why the authentication differs.

**Tech Stack:** Windows PowerShell / PowerShell, Jellyfin HTTP API, JSON.

## Global Constraints

- Jellyfin 10.11.x and earlier use the legacy `X-Emby-Token` header.
- Jellyfin 12.0 (including current Unstable) and later use `Authorization: MediaBrowser ... Token=...` because Jellyfin 12 disables legacy authorization by default.
- API keys must be passed through `-ApiKey`; no real key is committed.
- Both scripts export the same `ExportedAt`, `Libraries`, and `Items` structure.
- API failures stop the script instead of producing a misleading empty JSON file.
- Export is read-only: do not modify media, NFO, Jellyfin database, or server configuration.
- README changes are limited to the exact user-requested documentation pointer.

---

### Task 1: Add regression check and two exporters

**Files:**
- Create: `tests/check_library_export_scripts.ps1`
- Create: `scripts/export_jellyfin_library_10.ps1`
- Create: `scripts/export_jellyfin_library_12.ps1`

**Interfaces:**
- Consumes: `-ApiKey <string>` mandatory; optional `-Server <string>` and `-Output <string>`.
- Produces: a UTF-8 JSON file with `ExportedAt`, `Libraries`, and `Items`.

- [ ] **Step 1: Write the failing regression check**

The check must assert that both scripts exist, declare mandatory `ApiKey`, set `$ErrorActionPreference = "Stop"`, export the agreed item types and fields, and use only the expected authentication form for their version.

- [ ] **Step 2: Verify the check fails because the two scripts do not exist yet**

Expected failure: missing `scripts/export_jellyfin_library_10.ps1` and/or `scripts/export_jellyfin_library_12.ps1`.

- [ ] **Step 3: Implement the Jellyfin 10 exporter**

Use `X-Emby-Token`, pagination with a 500-item page size, `/Items` plus `/Library/VirtualFolders`, and `ConvertTo-Json -Depth 20`.

- [ ] **Step 4: Implement the Jellyfin 12 exporter**

Use the same export logic, but send `Authorization = "MediaBrowser Client=..., Device=..., DeviceId=..., Version=..., Token=..."`.

- [ ] **Step 5: Verify the regression check passes**

Expected: both scripts satisfy the static compatibility contract. Also verify neither script contains a hard-coded real API key or any write/delete Jellyfin endpoint.

### Task 2: Document usage and add README entry

**Files:**
- Create: `docs/library-export.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the two script names and parameter interface from Task 1.
- Produces: concise Chinese instructions for choosing the correct version and sharing the JSON with an AI or reviewer.

- [ ] **Step 1: Write `docs/library-export.md`**

Explain purpose, version split, API key parameter, example commands, optional server/output parameters, and the privacy warning that exports contain local paths/media inventory/provider IDs.

- [ ] **Step 2: Add exactly this README sentence without changing surrounding content**

`如果想快速（让 AI）核查本地元数据，可以查看 `docs/library-export.md` ！`

- [ ] **Step 3: Verify documentation matches actual filenames and parameters**

Expected: every documented command references an existing script and no example contains a real API key.

### Task 3: Final verification

**Files:**
- Verify all files above.

- [ ] **Step 1: Re-read changed files from the feature branch**

Confirm authentication split, fail-fast behavior, output schema, and exact README addition.

- [ ] **Step 2: Run static safety checks**

Confirm no destructive commands/endpoints, no committed secrets, and no unrelated README changes.

- [ ] **Step 3: Open a PR for review**

PR should summarize the two version-specific exporters, the Jellyfin 12 authorization change, and the documentation entry.