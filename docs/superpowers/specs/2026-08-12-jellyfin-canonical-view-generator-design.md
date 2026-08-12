# Jellyfin 243-target 规范视图生成器设计

## 目标

基于现有 `jellyfin_tv_nfo_run_log.csv` 中已经确认的 243 个 correction target，生成一层独立的 Jellyfin 专用规范视图，而不改名、不移动原始收藏文件。

第一版只负责可靠构建这 243 个目标的 canonical view、manifest 和构建日志；**不自动修改 Jellyfin 现有库路径，也不试图把整个 TV 库一次性镜像出来。**

后续若这一层稳定，再扩展为完整 TV 库规范视图。

## 固定目录布局

统一使用：

```text
D:\Resource\BangumiLink\
├─ View\
├─ Temp\
└─ Logs\
```

含义：

- `View`：长期存在、供 Jellyfin 后续使用的规范视图。
- `Temp`：构建过程中的 staging / probe / 临时文件。
- `Logs`：manifest 和每次构建日志。

硬约束：

- 本项目后续新建的 staging / probe / build 临时目录不得再放到 `D:\` 根目录。
- 默认临时根目录固定为 `D:\Resource\BangumiLink\Temp`。
- 旧的 `D:\_jellyfin_repair_staging` 不由第一版生成器自动删除；只有在单独确认其为空后再清理。

## 第一版范围

只处理满足以下条件的 243 个 correction target：

- 来自当前调查使用的 `jellyfin_tv_nfo_run_log.csv`；
- `RuleId != series-nfo`；
- `Action = WRITE`；
- 有明确 `VideoPath`、`Season`、`Episode`；
- 去重后目标总数必须严格等于 243。

第一版不做：

- 不扫描并镜像整个 TV 库；
- 不修改 Jellyfin library path；
- 不清理 jellyfin.db；
- 不调用 metadata FullRefresh；
- 不调用 `/Videos/{id}/AlternateSources`；
- 不改原始媒体文件名；
- 不移动原始媒体文件；
- 不自动处理 correction target 之外的 unknown member；
- 不顺手修正常文件。

## 规范视图路径

视图根目录：

```text
D:\Resource\BangumiLink\View
```

第一版按原 Jellyfin 库和作品组织：

```text
D:\Resource\BangumiLink\View\<LibraryName>\<Work>\
```

每个目标至少生成：

```text
SxxEyy - <原视频文件名>
SxxEyy - <原 NFO 文件名>
```

例如：

```text
S01E02 - [MingY] Kore Kaite Shine [02][WebRip][JPCN].mkv
S01E02 - [MingY] Kore Kaite Shine [02][WebRip][JPCN].nfo
```

`SxxEyy` 由 correction target 的 `Season` / `Episode` 生成，不从原字幕组文件名猜测。

## 视频与 NFO 的处理方式

### 视频

- 使用同盘 NTFS hardlink；
- 直接调用 Windows `CreateHardLinkW`；
- 不再使用 Windows PowerShell 5.1 的 `New-Item -ItemType HardLink`，因为实验 15 已确认带 `[02]` 一类文件名时 PowerShell provider 会错误解释路径；
- hardlink 建立前检查源与目标在同一 volume；
- hardlink 创建后立即验证目标存在且文件长度与源一致。

### NFO

- 使用普通文件复制，不使用 hardlink；
- 保持 XML 内容不变；
- 复制后文件名与 canonical 视频 basename 对齐。

选择复制 NFO 的原因：避免未来 Jellyfin 或人工修改 View 中 NFO 时反向改动原收藏目录中的 NFO。

## 合法同集多版本

不同原始文件如果 correction target 指向同一个 S/E，不自动认为冲突。

例如：

```text
S01E01 - version-A.mkv
S01E01 - version-B.mkv
```

可以同时存在。

真正的冲突定义为：两个不同 source 最终映射到**完全相同的 canonical target path**。遇到这种情况必须在 preflight 阶段停止，而不是覆盖。

## 预检

默认模式为 dry-run，只读取并计算，不创建 View 文件。

preflight 至少检查：

1. correction target 数量严格为 243；
2. 每个原视频存在；
3. 每个同 basename NFO 存在；
4. NFO XML 可解析；
5. NFO 中 `<season>` / `<episode>` 与 correction target 一致；
6. 能唯一确定原视频所属 Jellyfin library location；
7. canonical target path 可生成；
8. canonical 路径之间无完全冲突；
9. hardlink 源与 `View` 目标位于同一卷；
10. 已存在目标若不是当前 manifest 所管理的同一 source，则停止，不覆盖；
11. 不对 correction target 之外的 unknown member 做任何操作。

任何关键校验失败时，整个 Apply 不开始。

## 构建方式

正式执行使用显式 `-Apply`。

为了避免生成一半的 View 后才发现后续目标失败，流程分为两阶段：

### 阶段 1：计划与 staging

- 完成全部 243 个目标的 preflight；
- 生成本次 build plan；
- 在 `D:\Resource\BangumiLink\Temp\build-<timestamp>` 保存本次临时状态/计划数据；
- 此阶段不触碰原媒体。

### 阶段 2：构建 View

对每个目标：

1. 创建所需目录；
2. 用 `CreateHardLinkW` 创建 canonical 视频；
3. 校验 hardlink；
4. 复制 canonical NFO；
5. 校验 NFO 存在；
6. 记录该目标结果。

如果单个目标构建失败：

- 停止继续扩大；
- 删除本次 build 中已经新建且由本次 manifest 明确标记的 View 文件；
- 不删除历史已有、来源一致并已被 manifest 管理的文件；
- 原媒体始终不需要恢复，因为从未移动或改名。

## Manifest

长期 manifest：

```text
D:\Resource\BangumiLink\Logs\manifest.csv
```

每行至少包含：

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

manifest 是后续增量同步、验证、删除 stale link、以及最终扩展为完整 TV 库规范视图的基础。

第一版只写入由生成器实际确认/创建的 243-target 记录。

## 每次构建日志

每次运行额外生成：

```text
D:\Resource\BangumiLink\Logs\build-<timestamp>.csv
```

记录每个目标的：

- preflight 结果；
- hardlink 创建结果；
- NFO copy 结果；
- 是否复用既有 canonical 文件；
- 失败原因。

控制台输出只保留摘要和错误，不沿用实验 16 中 wrapper 导致的额外数字输出污染。

## 幂等性

生成器应允许重复运行。

如果 canonical 视频已经存在，并且 manifest 明确记录它来自同一个 `OriginalVideo`，且文件长度一致，则视为可复用，不重新创建。

如果 canonical NFO 已存在，并且对应同一 source，则允许覆盖复制，以保证 View NFO 与原 NFO 当前内容一致。

如果目标文件存在但 manifest 无法证明其来源，则停止，不猜测、不覆盖。

## Jellyfin 集成边界

第一版生成完成后：

- **不自动把 `View` 加入 Jellyfin；**
- **不自动移除现有原始库路径；**
- 只验证文件系统层面的 canonical view 是否完整、可重复生成、可审计。

原因：243-target 只覆盖异常子集，若立即切换 Jellyfin 到这个 View，会导致未纳入 View 的正常动画消失；若同时扫描原库与 View，又会产生重复。

因此第一版成功标准是“规范视图构建器可靠”，不是“整个 Jellyfin 已切换到新视图”。

## 第一版成功标准

一次 Apply 只有同时满足以下条件才算成功：

```text
planned targets = 243
preflight failures = 0
canonical videos ready = 243
canonical NFOs ready = 243
source media modified = 0
source media moved = 0
unmanaged target overwritten = 0
manifest ready = true
build log ready = true
```

并且再次 dry-run / Apply 时能把已正确存在的 View 识别为可复用，而不是制造重复文件。

## 后续阶段

第一版稳定后，再单独设计“完整 TV 库规范视图”：

- 正常文件也进入 View；
- correction targets 使用 canonical `SxxEyy -` 命名；
- 正常文件按安全规则 pass-through；
- 合法同集多版本保留；
- unknown member 明确分类；
- 最后才考虑让 Jellyfin 从原始季度目录迁移到完整 View。

这属于后续独立阶段，不塞进当前 243-target 第一版。