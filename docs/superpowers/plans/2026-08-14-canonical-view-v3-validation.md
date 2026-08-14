# Canonical View v3 Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留当前 v2 View 的同时，生成并行 v3 View，修复四个 Series 身份、光美单集目录/NCOP 和语言后缀字幕问题。

**Architecture:** `build_jellyfin_full_canonical_view.py` 继续负责纯 mapping，并新增显式 `layout_profile`；默认 `v2` 完全兼容现状，`v3` 才应用已确认的局部规则。`apply_jellyfin_full_canonical_view.py` 新增独立 `--view-root` / `--layout-profile`，v3 强制使用非默认 View 和独立 manifest，不继承 Phase 1。

**Tech Stack:** Python 3 标准库、unittest、NTFS hardlink、Jellyfin 12 HTTP API。

## Global Constraints

- 不修改/删除 `D:\Resource\BangumiLink\View` v2。
- 不修改任何原始媒体路径。
- v3 只固定四个已确认问题 Series；不全库泛化 provider pin。
- v3 只压平 `precure` correction targets；NCOP/ED 进入 `extras`。
- v2 sidecar 行为保持不变；语言后缀 sidecar 只在 v3 启用。
- v3 不自动切换 Jellyfin 生产库。

---

### Task 1: v3 mapping rules

**Files:**
- Modify: `scripts/build_jellyfin_full_canonical_view.py`
- Test: `tests/test_full_canonical_view.py`

**Interfaces:**
- Produces: `build_mapping(files, targets, view_root, layout_profile="v2")`
- Produces: v3 series pin / sidecar / precure path helpers

- [ ] **Step 1: Write failing tests**

Add tests proving:

```python
# v2 keeps video.chs.ass passthrough; v3 follows S01E02
# v3 pins only the four exact 2026-01 Series folders
# v3 maps precure target video/NFO/subtitles into Season 01
# v3 maps NCOP_ED_01 into extras without SxxEyy
```

- [ ] **Step 2: Run tests and confirm RED**

Run:

```bash
python -m unittest tests.test_full_canonical_view -v
```

Expected: new v3 assertions fail because the profile/rules do not exist.

- [ ] **Step 3: Implement minimal v3 mapping**

Keep `v2` as default. Add exact rule constants and helpers; do not alter unrelated mappings.

- [ ] **Step 4: Run tests and confirm GREEN**

```bash
python -m unittest tests.test_full_canonical_view -v
```

Expected: all existing + new tests pass.

### Task 2: isolated v3 apply target

**Files:**
- Modify: `scripts/apply_jellyfin_full_canonical_view.py`
- Test: `tests/test_full_canonical_view_apply.py`

**Interfaces:**
- CLI: `--layout-profile {v2,v3}`
- CLI: `--view-root <path>`
- v3 default manifest: `Logs\full-manifest-v3.csv`

- [ ] **Step 1: Write failing tests**

Add tests proving:

```python
# default v2 still resolves root\View + full-manifest-v2.csv + Phase1 seed
# v3 requires a non-default View root
# v3 uses full-manifest-v3.csv and no Phase1 seed
```

- [ ] **Step 2: Run tests and confirm RED**

```bash
python -m unittest tests.test_full_canonical_view_apply -v
```

- [ ] **Step 3: Implement minimal CLI/preflight changes**

Pass `layout_profile` into mapping. For v3, refuse the default `View`, use independent manifest, and skip Phase 1 seeding.

- [ ] **Step 4: Run tests and confirm GREEN**

```bash
python -m unittest discover -s tests -p 'test_full_canonical_view*.py' -v
python -m py_compile scripts/build_jellyfin_full_canonical_view.py scripts/apply_jellyfin_full_canonical_view.py
```

Expected: all Python Full View tests pass and both scripts compile.

### Task 3: documentation and real preflight handoff

**Files:**
- Modify: `docs/canonical-view.md`

- [ ] **Step 1: Document v2/v3 separation and exact read-only command**

Use:

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
  --api-key "<API_KEY>" `
  --layout-profile v3 `
  --view-root "D:\Resource\BangumiLink\View-v3"
```

Do not instruct `--apply` until this preflight is clean.

- [ ] **Step 2: Commit tested files and ask only for the real Windows v3 preflight output**
