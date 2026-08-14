# Jellyfin 规范视图

本仓库已经从“只靠 NFO 修正 Jellyfin”进一步发展为“给 Jellyfin 提供规范输入”。调查确认：NFO 可以修正 Episode 自身的季号/集号，但 Jellyfin 可能在读取 NFO 之前就根据完整路径建立错误的 `LocalAlternateVersion`。因此规范视图保留原始收藏不动，只给 Jellyfin 提供更明确的路径/文件名。

## Phase 1：243 个已确认修正目标

已经真实验证的 Phase 1 仍使用 PowerShell：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

确认 dry-run 后才使用 `-Apply`。它只处理 `jellyfin_tv_nfo_run_log.csv` 中经过筛选、去重的 243 个 correction targets：视频在 View 中使用 `SxxEyy - <原文件名>` hardlink，同 basename NFO 使用 copy。

2026-08-13 的真实 Apply 已验证：243 个视频和 243 个 NFO 全部生成；第二次 dry-run 为 243/243 reusable；原始媒体没有被移动或修改。

**Phase 1 View 是 partial view，不能单独替换完整 TV 库，也不能和对应的原始 D 盘 TV root 同时挂入生产媒体库。**

## Phase 2：D 盘 TV canonical View，改用 Python

最初的 Phase 2 PowerShell 实现已经停止维护。真实 Windows 运行暴露了运行时 regex/转义问题，也说明继续在 PowerShell 上扩大复杂度的收益很低。未完成的 Phase 2 因此改用 Python；旧 PS 尝试保留在 git 历史中，不再作为当前入口。

当前分成两个明确入口：

```text
scripts/build_jellyfin_full_canonical_view.py
scripts/apply_jellyfin_full_canonical_view.py
```

前者始终只读，用于 inventory + mapping；后者默认也只做完整 preflight，只有显式 `--apply` 才会写 View。

## 两个必须区分的数量：生产 TV 676，D 盘 View scope 634

2026-08-14 的 root 诊断最终确认当前 Jellyfin 有 11 个 `tvshows` root entries、678 个视频：

- 9 个 `D:\Bangumi` 正式 TV roots：634 个视频；
- `C:\bangumi`，媒体库名 `杂项TV动画`：42 个视频；
- `D:\Jellyfin-Repro`，媒体库名 `test`：2 个视频。

因此：

```text
生产 TV 总量 = 634 + 42 = 676
全部 tvshows = 676 + 2 test = 678
```

旧统一 audit 的 676 没有算错。之前的错误是把 `C:\bangumi` 先验地当成测试目录，导致一度把 D 盘 634 误称为“生产 TV 总量”。

Phase 2 仍只构建 634 个 D 盘视频的 canonical View，原因不是 `C:\bangumi` 非生产，而是：

1. View 位于 `D:\Resource\BangumiLink\View`；
2. C 盘视频不能 hardlink 到 D 盘；
3. 243 个 confirmed correction targets 已全部位于这 634 个 D 盘视频中；
4. 因此当前没有必要复制 42 个 C 盘视频来制造一份冗余 View。

`C:\bangumi` 是 **external production TV**：后续生产切换时保持原媒体库/root 不动。只有 9 个 D 盘 TV roots 由 canonical View 接管。

只读 root 口径诊断：

```powershell
python .\scripts\diagnose_jellyfin_tv_roots.py `
    --api-key "<API_KEY>"
```

当前分类语义：

- `VIEW_SCOPE`：进入 D 盘 canonical View；
- `EXTERNAL_PRODUCTION`：正式 TV，但保持原 root，例如 `C:\bangumi`；
- `TEST`：测试库，例如 `D:\Jellyfin-Repro`；
- `OUT_OF_VIEW`：明确不属于当前 canonical View 的范围；
- `AMBIGUOUS`：root 边界重叠，必须停止处理。

## Read-only inventory / mapping

运行：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

它当前只对 D 盘 View scope 生成 mapping：

- filesystem videos：634；
- Jellyfin expanded Episode paths：634；
- `JELLYFIN_ONLY = 0`；
- `FILESYSTEM_ONLY = 0`；
- correction videos：243；
- correction sidecars：243；
- passthrough videos：391；
- passthrough files：350；
- 完整 source mapping：1227 行。

不会创建或修改 `View`、`Temp`、`Logs`，不会 Refresh/Identify/修改 Jellyfin，也不会写 NFO/SQLite。

## Full View preflight / Apply

写入入口：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

**不带 `--apply` 时仍然是只读 preflight。** 这里的默认 634 是 D 盘 View scope 断言，不是生产 TV 总量；生产 TV 总量仍是 676。

preflight 会检查：

- D 盘 View scope 视频仍为 634；
- 243 个 target NFO 的 `<season>/<episode>` 与 correction 记录一致；
- filesystem 634 与 Jellyfin expanded 634 完全一致；
- hardlink 不跨卷；
- Phase 1 `Logs\manifest.csv` 能解释现有 243 video + 243 NFO；
- View 中没有 unmanaged / stale 文件；
- 已存在 hardlink 必须与 source 为同一个文件；
- 已存在 copy 必须与 source 内容一致；
- full manifest 不允许改变 canonical path 的 source ownership。

2026-08-14 真实 Windows preflight 已得到：

```text
Production roots:   9
Source files:       1227
Source videos:      634
Correction targets: 243
Reusable rows:      486
Rows to create:     741
Conflicts:          0
```

其中 486 reusable 正好对应 Phase 1 已存在的 243 video hardlinks + 243 NFO copies。

确认 preflight 无冲突后，实际构建命令为：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>" `
    --apply
```

Apply 会：

- 对 D 盘 View scope 中的视频和 `.ass/.ssa/.srt/.vtt/.sub/.idx` 创建同盘 hardlink；
- 对 NFO、metadata 和其他普通文件 copy；
- 写 `Logs\full-manifest-v2.csv` 和本次 build log；
- 失败且 manifest 尚未提交时，只回滚本次 build 新建的 View destination；
- 不使用 source path 做删除；
- 不移动、重命名或覆盖原始收藏；
- 不修改 `C:\bangumi`；
- 不自动修改 Jellyfin library root。

Python 事务核心已在开发环境真实执行 fixture，覆盖 hardlink/copy、第二次 reusable、Phase 1 manifest ownership、NFO identity 和失败 rollback。真实 Windows 生产 Apply 仍未执行。

## Phase 2 最终语义

- 原始收藏不移动、不重命名；
- 只给 243 confirmed targets 增加 `SxxEyy -`；
- target 同 basename sidecar 跟随重命名；
- 其他 D 盘 View-scope 文件保持原相对目录和文件名透传；
- `C:\bangumi` 42 个杂项 TV 动画作为 external production 保持原地；
- 33 个 non-target hidden / extras 不自动解释；
- 不做 Episode title / Overview 修复；
- 不修改 Jellyfin SQLite；
- Full View 完成后也不会自动切换生产 library root。

后续生产切换的正确目标不是“所有 TV 都变成一个 D 盘 View”，而是：**9 个 D 盘 TV roots 切到 canonical View；`C:\bangumi` 继续作为独立正式 TV root 保留。**

Python 迁移设计与实现计划：

```text
docs/superpowers/specs/2026-08-14-full-canonical-view-python-design.md
docs/superpowers/plans/2026-08-14-full-canonical-view-python.md
```

原 PowerShell Phase 2 的 spec/plan 仅作为历史调查记录，不再代表当前实现。
