# Jellyfin 规范视图

本仓库已经从“只靠 NFO 修正 Jellyfin”进一步发展为“给 Jellyfin 提供规范输入”。调查确认：NFO 可以修正 Episode 自身的季号/集号，但 Jellyfin 可能在读取 NFO 之前就根据完整路径建立错误的 `LocalAlternateVersion`。因此规范视图保留原始收藏不动，只给 Jellyfin 提供更明确的路径/文件名。

## Phase 1：243 个已确认修正目标

已经真实验证的 Phase 1 仍使用 PowerShell：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

确认 dry-run 后才使用 `-Apply`。它只处理 `jellyfin_tv_nfo_run_log.csv` 中经过筛选、去重的 243 个 correction targets：视频在 View 中使用 `SxxEyy - <原文件名>` hardlink，同 basename NFO 使用 copy。

2026-08-13 的真实 Apply 已验证：243 个视频和 243 个 NFO 全部生成；第二次 dry-run 为 243/243 reusable；原始媒体没有被移动或修改。

**Phase 1 View 是 partial view，不能单独替换完整 TV 库，也不能和原始 TV 根目录同时挂入生产媒体库。**

## Phase 2：完整 TV View，改用 Python

最初的 Phase 2 PowerShell 实现已经停止维护。真实 Windows 运行暴露了运行时 regex/转义问题，也说明继续在 PowerShell 上扩大复杂度的收益很低。未完成的 Full View Phase 2 因此改用 Python；旧 PS 尝试保留在 git 历史中，不再作为当前入口。

当前分成两个明确入口：

```text
scripts/build_jellyfin_full_canonical_view.py
scripts/apply_jellyfin_full_canonical_view.py
```

前者始终只读，用于 inventory + mapping；后者默认也只做完整 preflight，只有显式 `--apply` 才会写 View。

## 当前生产 TV 基线：634，不是 676

Python read-only inventory 已在真实 Windows + Jellyfin 12.0.0 环境运行：

- 选中 9 个生产 TV roots；
- filesystem videos：634；
- Jellyfin expanded Episode paths：634；
- `JELLYFIN_ONLY = 0`；
- `FILESYSTEM_ONLY = 0`；
- correction videos：243；
- correction sidecars：243；
- passthrough videos：391；
- passthrough files：350。

因此当前完整 source mapping 一共 1227 行，其中视频正好 634 个。

旧统一 audit 中的 676 并不是 Phase 2 的生产 TV 基线。旧 analyzer 只从所有 `CollectionType=tvshows` 项目里排除了 `LibraryName == "test"`，因此仍会把生产 TV 范围之外、但类型同样为 `tvshows` 的非-test root 算进去；当前 Phase 2 明确冻结并排除 `D:\Gekijouban`。以后 676 只保留为旧 audit 的宽口径历史统计，不再作为 Full View 数量断言。

## Read-only inventory / mapping

运行：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

它会：

1. 读取 Jellyfin `/Library/VirtualFolders`；
2. 选择 `CollectionType=tvshows` locations；
3. 排除 `C:\bangumi`、`D:\Jellyfin-Repro`、`D:\Gekijouban` 和 View；
4. 枚举实际文件；
5. 读取 expanded Episode 实际路径；
6. 输出 filesystem/Jellyfin 双向差集；
7. 读取 243 correction targets 并生成完整 mapping。

不会创建或修改 `View`、`Temp`、`Logs`，不会 Refresh/Identify/修改 Jellyfin，也不会写 NFO/SQLite。

## Full View preflight / Apply

新的写入入口：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

**不带 `--apply` 时仍然是只读 preflight。** 当前默认断言生产视频为 634、correction targets 为 243。

preflight 还会额外检查：

- 243 个 target NFO 的 `<season>/<episode>` 与 correction 记录一致；
- filesystem 634 与 Jellyfin expanded 634 仍然完全一致；
- hardlink 不跨卷；
- Phase 1 `Logs\manifest.csv` 能解释现有 243 video + 243 NFO；
- View 中没有 unmanaged / stale 文件；
- 已存在 hardlink 必须与 source 为同一个文件；
- 已存在 copy 必须与 source 内容一致；
- full manifest 不允许改变 canonical path 的 source ownership。

在当前 Phase 1 View 未被额外修改的情况下，预期首次完整 preflight 应看到：

```text
Reusable rows: 486
Rows to create: 741
Conflicts: 0
```

只有真实 preflight 输出确认无冲突后，才考虑：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>" `
    --apply
```

Apply 会：

- 对视频和 `.ass/.ssa/.srt/.vtt/.sub/.idx` 创建同盘 hardlink；
- 对 NFO、metadata 和其他普通文件 copy；
- 写 `Logs\full-manifest-v2.csv` 和本次 build log；
- 失败且 manifest 尚未提交时，只回滚本次 build 新建的 View destination；
- 不使用 source path 做删除；
- 不移动、重命名或覆盖原始收藏；
- 不自动修改 Jellyfin library root。

Python 事务核心已在开发环境真实执行 fixture，覆盖 hardlink/copy、第二次 reusable、Phase 1 manifest ownership、NFO identity 和失败 rollback。真实 Windows 生产 Apply 仍未执行。

## Phase 2 最终语义

- 原始收藏不移动、不重命名；
- 只给 243 confirmed targets 增加 `SxxEyy -`；
- target 同 basename sidecar 跟随重命名；
- 其他文件保持原相对目录和文件名透传；
- 33 个 non-target hidden / extras 不自动解释；
- 不做 Episode title / Overview 修复；
- 不修改 Jellyfin SQLite；
- Full View 完成后也不会自动切换生产 library root。

Python 迁移设计与实现计划：

```text
docs/superpowers/specs/2026-08-14-full-canonical-view-python-design.md
docs/superpowers/plans/2026-08-14-full-canonical-view-python.md
```

原 PowerShell Phase 2 的 spec/plan 仅作为历史调查记录，不再代表当前实现。
