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
- `Logs`：`manifest.csv` 和每次 Apply 的构建日志。

新脚本不会在 `D:\` 根目录新建 staging/probe/temp 目录。

## 当前范围

第一版只处理 `jellyfin_tv_nfo_run_log.csv` 中经过筛选、去重后的 **243 个 correction targets**：

- `RuleId != series-nfo`
- `Action = WRITE`
- 有明确 `VideoPath / Season / Episode`

这 243 个目标只是现有 TV 动画库的一小部分。因此：

**当前 View 不能直接替换完整 Jellyfin TV 库，也不应与原始 TV 根目录同时挂到主媒体库中。**

只扫描 View 会让其他正常动画消失；同时扫描原始目录和 View 又会让这 243 个目标重复出现。完整切库要等后续“全库镜像/透传 hardlink”阶段完成。

## 使用

### 1. Dry-run

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 `
    -ApiKey "<API_KEY>"
```

Dry-run 只读取：

- Jellyfin `/System/Info`
- Jellyfin `/Library/VirtualFolders`
- correction run log
- 原视频 / 原 NFO
- 已存在的 `Logs\manifest.csv`（若存在）

它不会创建 `View`、`Temp` 或 `Logs` 内容。

正常首次构建前应看到：

```text
Planned targets:      243
Preflight failures:   0
Videos reusable:      0
Videos to create:     243
NFOs reusable:        0
NFOs to create:       243
```

### 2. Apply

确认 dry-run 映射无误后：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 `
    -ApiKey "<API_KEY>" `
    -Apply
```

Apply 会先重新完成全部 preflight；任何 target 预检失败时不会开始写文件。

预检通过后：

1. 在 `Temp\build-<timestamp>` 保存本次计划；
2. 在 View 中建立需要的目录；
3. 用 native `CreateHardLinkW` 创建 canonical 视频；
4. 复制 canonical NFO；
5. 逐项验证文件存在和视频长度；
6. 成功后写 `Logs\manifest.csv` 和 `Logs\build-<timestamp>.csv`。

脚本兼容 Windows PowerShell 5.1，并对本库中已经出现的超长 Windows 路径使用 native Windows 文件 API，避免传统 `MAX_PATH` 限制和 PowerShell hardlink provider 对 `[]` 路径的误处理。

## Manifest 与重复运行

`Logs\manifest.csv` 记录 canonical target 与原始源文件之间的对应关系，至少包括：

```text
Work
LibraryName
OriginalVideo
OriginalNfo
ExpectedSeason
ExpectedEpisode
ExpectedKey
CanonicalVideo
CanonicalNfo
VideoLength
BuildId
Status
```

已经存在的 canonical 文件只有在 manifest 能证明它来自同一源文件，并且视频长度符合预期时，才会被判定为 `REUSABLE`。

已存在但无法由 manifest 证明来源的目标文件会直接导致 preflight 失败，不会被覆盖。

2026-08-13 的首次实际 Apply 结果：

```text
planned targets = 243
preflight failures = 0
canonical videos ready = 243
canonical NFOs ready = 243
videos created = 243
videos reused = 0
NFOs created = 243
NFOs reused = 0
source media modified = 0
source media moved = 0
unmanaged target overwritten = 0
manifest ready = true
build log ready = true
```

随后再次 dry-run：

```text
Existing manifest rows: 243
Planned targets:      243
Preflight failures:   0
Videos reusable:      243
Videos to create:     0
NFOs reusable:        243
NFOs to create:       0
```

这验证了第一版 243-target View 的幂等复用行为。

## 失败与回滚边界

Apply 中途失败时，脚本停止继续扩展，并只尝试删除**本次 build 新创建**的 canonical 视频/NFO 和本次新建且仍为空的 View 目录。

它不会因为回滚而删除：

- 原始视频；
- 原始 NFO；
- 以前 build 已经由 manifest 管理的文件；
- correction targets 之外的未知媒体文件。

如果 rollback 本身出现错误，脚本会保留 build temp / failure log 供人工检查，而不是继续猜测性清理。

## 与旧 NFO 脚本的关系

`jellyfin_tv_nfo_fix.ps1` 和已有规则没有作废。它们现在承担的是“确定正确身份”的上游工作：

```text
字幕组原始文件
        ↓
规则 / NFO / correction run log
        ↓
正确的 Season / Episode
        ↓
build_jellyfin_canonical_view.ps1
        ↓
SxxEyy - <原文件名>
        ↓
Jellyfin 规范输入
```

也就是说，NFO 从“最终修复手段”转成了规范视图的重要元数据来源。

完整原因与实验链见：

```text
docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md
experiments/jellyfin12-nfo-refresh/README.md
```
