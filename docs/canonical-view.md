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

最初的 Phase 2 PowerShell 实现已经停止维护。真实 Windows 运行先暴露了运行时 regex/转义错误；修复后又出现 `676` 生产基线只枚举到 `634` 的问题。继续在 PowerShell 上补丁的收益已经很低，因此未完成的 Full View Phase 2 改用 Python；旧 PS 尝试保留在 git 历史中，不再作为当前入口。

当前入口：

```text
scripts/build_jellyfin_full_canonical_view.py
```

### 当前阶段只做 read-only inventory + mapping

现在**没有 `--apply`**。Python 版第一阶段只负责先解释生产文件全集：

1. 读取 Jellyfin `/Library/VirtualFolders`；
2. 选择 `CollectionType=tvshows` locations；
3. 排除 `C:\bangumi`、`D:\Jellyfin-Repro`、`D:\Gekijouban` 和 View；
4. 枚举实际文件；
5. 通过 `/Items?IncludeItemTypes=Episode&VideoTypes=VideoFile` 读取 expanded Episode 实际路径；
6. 输出 filesystem 与 Jellyfin 两套视频集合及双向差集；
7. 读取 243 correction targets 并生成完整 mapping，但不写文件。

与旧 PS Full View 不同，Python 版**不再假定唯一生产根是 `D:\Bangumi`**，而是以 Jellyfin 当前所有 TV locations 为准，再明确排除测试根。这一步正是用来判断此前 `634 != 676` 是否来自生产根筛选错误。

运行：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

输出重点包括：

```text
Selected TV roots
Filesystem videos
Jellyfin expanded Episode paths in selected roots
JELLYFIN_ONLY
FILESYSTEM_ONLY
Mapping roles
```

此阶段不会创建或修改 `View`、`Temp`、`Logs`，不会 Refresh/Identify/修改 Jellyfin，也不会写 NFO/SQLite。

Python 纯逻辑测试：

```powershell
python -m unittest .\tests\test_full_canonical_view.py -v
```

开发端已经实际用 Python 3 跑过该测试文件；生产 Windows 文件枚举和 Jellyfin API 结果仍以用户机器真实 dry-run 为准。

## Phase 2 最终语义不变

只有第一阶段把 676 基线解释清楚后，才会实现 Apply。届时仍遵守：

- 原始收藏不移动、不重命名；
- 只给 243 confirmed targets 增加 `SxxEyy -`；
- target 同 basename sidecar 跟随重命名；
- 其他文件保持原相对目录和文件名透传；
- 视频/明显只读字幕使用 hardlink；
- NFO、metadata 和未知普通文件使用 copy；
- 33 个 non-target hidden / extras 不自动解释；
- 不做 Episode title / Overview 修复；
- 不修改 Jellyfin SQLite；
- Full View 完成后也不会自动切换生产 library root。

完整 Python 迁移设计与短实现计划：

```text
docs/superpowers/specs/2026-08-14-full-canonical-view-python-design.md
docs/superpowers/plans/2026-08-14-full-canonical-view-python.md
```

原 PowerShell Phase 2 的 spec/plan 仅作为历史调查记录，不再代表当前实现。
