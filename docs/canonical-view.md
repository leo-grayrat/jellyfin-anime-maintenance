# Jellyfin 规范视图

本仓库已经从“只靠 NFO 修正 Jellyfin”进一步发展为“给 Jellyfin 提供规范输入”。

前面的调查确认：NFO 可以把 Episode 自身的季号、集号改正确，但 Jellyfin 可能在读取 NFO 之前就根据完整路径把不同物理文件错误组织为 `LocalAlternateVersion`。因此，NFO 仍然保留为正确身份信息，但不再承担完整修复职责。

规范视图的做法是：**不改原始收藏目录，而是在同一磁盘上为 Jellyfin 生成带显式 `SxxEyy` 前缀的文件视图。**

例如原文件：

```text
D:\Bangumi\2026\2026-07\作品目录\[字幕组] 作品 [02].mkv
```

会在 View 中得到：

```text
D:\Resource\BangumiLink\View\<Jellyfin媒体库名>\作品目录\S01E02 - [字幕组] 作品 [02].mkv
```

视频使用 NTFS hardlink，不复制视频内容；同 basename 的 NFO 使用普通文件复制，因此 Jellyfin 对 View 中 NFO 的后续修改不会反向改变原始 NFO。

## 目录

固定工作根目录：

```text
D:\Resource\BangumiLink\
├─ View\
├─ Temp\
└─ Logs\
```

- `View`：长期保留的 Jellyfin 规范视图。
- `Temp`：Apply 时的临时构建状态。
- `Logs`：manifest 和每次 Apply 的构建日志。

新脚本不会在 `D:\` 根目录新建 staging/probe/temp 目录。

## Phase 1：243 个已确认修正目标

第一版只处理 `jellyfin_tv_nfo_run_log.csv` 中经过筛选、去重后的 **243 个 correction targets**：

- `RuleId != series-nfo`
- `Action = WRITE`
- 有明确 `VideoPath / Season / Episode`

Phase 1 使用：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

确认 dry-run 后：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>" -Apply
```

它只为 243 个目标创建显式 `SxxEyy - <原文件名>` 视频 hardlink，并复制对应 NFO。`Logs\manifest.csv` 是 Phase 1 的来源证明。

2026-08-13 的真实 Apply 已验证：243 个视频和 243 个 NFO 全部生成，随后第二次 dry-run 为 243/243 reusable；原始媒体没有被移动或修改。

**Phase 1 View 仍然是 partial view，不能单独替换完整 TV 库，也不能和原始 TV 根目录同时挂入生产媒体库。**

## Phase 2：完整 TV View

Phase 2 新增：

```text
scripts/build_jellyfin_full_canonical_view.ps1
scripts/lib/full_canonical_view_common.ps1
scripts/lib/full_canonical_view_apply.ps1
```

目标是让 View 覆盖整个生产 TV 文件集合，而不是只覆盖 243 个修正目标。

当前规则是：

- 生产源默认只接受 `D:\Bangumi` 下的 `CollectionType=tvshows` Jellyfin location；
- 当前生产视频基线固定校验为 676；
- 243 个 correction videos 使用显式 `SxxEyy - ` 前缀；
- 与 correction video 同目录、file stem 完全相同的非视频 sidecar 跟随相同前缀；
- 其余视频和文件保持原相对目录与原文件名，不自动推断 S/E；
- 视频和 `.ass/.ssa/.srt/.vtt/.sub/.idx` 使用同盘 hardlink；
- NFO 以及其他未知/metadata 文件默认 copy；
- 未知文件优先保留，不静默丢弃；
- `C:\bangumi`、`D:\Jellyfin-Repro` 和 `D:\Gekijouban` 不在默认生产范围内。

这意味着 33 个 non-target hidden、SP、OVA、NCOP/NCED、PV、menu、Bonus 等不会因为 Phase 2 而被自动重新解释。

### Phase 2 dry-run

目前应先运行测试，然后只做 dry-run：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\build_jellyfin_full_canonical_view.ps1 `
    -ApiKey "<API_KEY>"
```

preflight 会至少验证：

- 生产视频数量仍为 676；
- correction targets 仍为 243；
- 243 个 target 都属于生产 source inventory；
- target NFO 的 season/episode 仍与 correction 记录一致；
- source roots 与 View 不互相包含；
- canonical path 不碰撞；
- hardlink 不跨盘；
- Phase 1 manifest 与现有 243 target video/NFO 仍能对应；
- `Logs\full-manifest-v2.csv` 中没有已经脱离当前 source plan 的陈旧条目；
- View 中没有无法由 Phase 1/Phase 2 manifest 解释的现存文件；
- 已有目标只能是 `REUSABLE`，否则为冲突，绝不覆盖 unmanaged 文件。

Dry-run 不创建 View/Temp/Logs 内容。

### Phase 2 Apply

代码支持显式 `-Apply`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\build_jellyfin_full_canonical_view.ps1 `
    -ApiKey "<API_KEY>" `
    -Apply
```

但在真实 Windows PowerShell 5.1 dry-run 输出被核对前，不应执行生产 Apply。

Apply 会重新完整 preflight 一次，然后：

1. 在 `Temp\full-build-<timestamp>` 固化本次 plan；
2. 只创建 plan 中状态为 `MISSING` 的 hardlink/copy；
3. 对 `REUSABLE` 项不重建；
4. 每项创建后验证目标存在且长度与 source 一致；
5. 写新的 per-file `Logs\full-manifest-v2.csv`；
6. manifest 先写临时文件，再通过 native replace 原子替换；
7. 若 manifest commit 之前失败，只回滚本次 build 新创建、且路径仍位于 View 下的 destination；
8. rollback 不使用 source path，也不会删除此前 build 已管理的文件。

Phase 2 不修改 Jellyfin library root。完整 View 构建成功之后，仍需在独立验证库确认结构，再人工决定是否切生产库。

## Full manifest v2

Phase 2 的 `Logs\full-manifest-v2.csv` 是逐文件账本，包含：

```text
SourcePath
CanonicalPath
LibraryName
Role
Operation
SourceLength
ExpectedKey
BuildId
Status
```

角色包括：

```text
CORRECTION_VIDEO
CORRECTION_SIDECAR
PASSTHROUGH_VIDEO
PASSTHROUGH_FILE
```

Phase 1 的 `Logs\manifest.csv` 不会被改写；首次 Phase 2 preflight 会把它仅作为已有 243 个 correction video/NFO 的来源证明，成功 Apply 后再由 manifest v2 接管整个 View 的逐文件追踪。

## 测试

Phase 2 新增的安全测试包括：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_common.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_command.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_full_canonical_view_apply.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check_windows_powershell_compat.ps1
```

`test_full_canonical_view_apply.ps1` 只在 `%TEMP%` 下建立 fixture，验证：首次 hardlink/copy、manifest-v2、第二次全量 reusable，以及故意失败时只回滚 View destination、不删除 source。

本仓库当前开发环境无法运行 Windows PowerShell，因此这些测试必须以用户 Windows 机器实际输出为准；在看到真实 PASS 前，不把它们记为已通过。

## 与旧 NFO 脚本的关系

`jellyfin_tv_nfo_fix.ps1` 和已有规则没有作废。它们承担“确定正确身份”的上游工作：

```text
字幕组原始文件
        ↓
规则 / NFO / correction run log
        ↓
正确的 Season / Episode
        ↓
canonical view
        ↓
已确认目标：SxxEyy - <原文件名>
其他媒体：原样透传
        ↓
Jellyfin 规范输入
```

完整原因、设计与实现计划见：

```text
docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md
docs/superpowers/specs/2026-08-14-full-canonical-view-phase2-design.md
docs/superpowers/plans/2026-08-14-full-canonical-view-phase2.md
```
