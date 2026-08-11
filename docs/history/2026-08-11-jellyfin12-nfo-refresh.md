# 2026-08-11 Jellyfin 12 NFO 刷新调查记录

本文记录从“Jellyfin 12 是否已经修复 episode NFO 季号覆盖问题”开始，到批量修复 243 个目标、再定位 Fate/strange Fake 特例的完整过程。

目的不是写一篇事后整理成“每一步都正确”的说明，而是保留：

- 当时使用了什么脚本；
- 实际运行得到了什么；
- 哪个判断因此成立；
- 哪个判断后来被推翻；
- 下一步为什么改变方向。

一次性脚本和脱敏结果见：

```text
experiments/jellyfin12-nfo-refresh/
```

## 背景

旧问题的核心是：字幕组文件名常常无法让 Jellyfin 正确判断动画季数。仓库已经通过 episode NFO 写入目标 `<season>` / `<episode>`，但旧 Jellyfin 版本会让路径解析得到的季号覆盖 NFO 季号。

Jellyfin 上游 PR #16702（`Honor episode NFO season during metadata merge`）修复了该问题，且该修复已经包含在本次测试使用的 Jellyfin 12 RC/正式构建中。

本轮实际目标不是只验证“源码里有修复”，而是确认：

1. 已经存在于数据库里的旧错误 Episode 能否通过 NFO 修回来；
2. Season 层级关系是否会同步重挂；
3. 能否把这个过程自动化到本仓库的维护脚本里。

---

## 阶段 1：最早单集测试失败，HTTP 400

### 脚本

`experiments/jellyfin12-nfo-refresh/01-single-episode-refresh-broken.ps1`

### 做法

选取 SPY×FAMILY Season 3 的第 7 集作为单集测试对象，先读取当前状态，再对该 Episode 发：

```text
POST /Items/{itemId}/Refresh
metadataRefreshMode=FullRefresh
replaceAllMetadata=false
replaceAllImages=false
```

### 实际结果

读取状态阶段直接失败：

```text
=== Before FullRefresh ===
Invoke-RestMethod : 远程服务器返回错误: (400) 错误的请求。
```

### 结论

**已推翻：** “API Key 可以直接用 `GET /Items/{itemId}` 读取单个条目”这一假设。

该接口路径在当前认证场景下不适合作为脚本读取入口。随后改用已经在导出脚本里验证过的：

```text
GET /Items?Ids={itemId}
```

---

## 阶段 2：Episode FullRefresh 确认读取 NFO 季号

### 脚本

`experiments/jellyfin12-nfo-refresh/02-single-episode-refresh.ps1`

### 对象

SPY×FAMILY Season 3，第 7 集。

### 刷新前

```text
IndexNumber       : 7
ParentIndexNumber : 1
SeasonName        : 第 1 季
SeasonId          : 13c0f408fbfad2afc82b81a145541d5b
SeriesId          : 2352f89ff3f68c12de46b149cd8488b0
```

### Episode FullRefresh 后

第三次轮询时变为：

```text
IndexNumber       : 7
ParentIndexNumber : 3
SeasonName        : 第 1 季
SeasonId          : 13c0f408fbfad2afc82b81a145541d5b
```

### 结论

**已证实：** Jellyfin 12 的 Episode FullRefresh 确实尊重 episode NFO 中显式 `<season>3</season>`，`ParentIndexNumber` 从 1 变成 3。

这说明上游 #16702 的核心修复在真实媒体库中生效。

同时暴露第二层问题：

```text
ParentIndexNumber = 3
SeasonId          = 仍然指向第 1 季
SeasonName        = 仍然是第 1 季
```

因此只刷新 Episode 不足以完成 Jellyfin UI 层级重挂。

---

## 阶段 3：Series FullRefresh 可以完成已有 Season 的重挂

### 脚本

`experiments/jellyfin12-nfo-refresh/03-series-relink.ps1`

### 做法

先确认该 Series 下已经存在真实 Season 3：

```text
Season 3 ID: b044401aabe3b12687c369f110275e9c
```

然后刷新整个 Series。

### 实际结果

第一次轮询即完成：

```text
ParentIndexNumber : 3
SeasonName        : 第 3 季
SeasonId          : b044401aabe3b12687c369f110275e9c
```

### 结论

**已证实：** 对于目标 Season 对象已经存在的情况，完整修复链路是：

```text
Episode FullRefresh
    -> NFO 修正 ParentIndexNumber
Series FullRefresh
    -> 重新计算 SeasonId / SeasonName
```

至此决定把这两阶段逻辑做成批量脚本。

---

## 阶段 4：建立批量刷新脚本

### Git 版本 1：初版

Commit：

```text
c7c8042499bd17968f65369f5064c142fba23abf
```

功能：

1. 读取 `jellyfin_tv_nfo_run_log.csv`；
2. 按 VideoPath 找对应 Episode；
3. 只对季/集号不匹配的 Episode 发 FullRefresh；
4. 等 Episode 达到目标季/集；
5. 按 SeriesId 去重；
6. 对相关 Series 发 FullRefresh；
7. 检查 `ParentIndexNumber`、`IndexNumber`、`SeasonId`；
8. 输出 `jellyfin_tv_nfo_refresh_log.csv`。

### Git 版本 2：PowerShell/边界加固

Commit：

```text
bc478d933fec66f75693fdd48210f4ff19b7dbeb
```

主要修正：

- 处理空 `ParentIndexNumber` / `IndexNumber`；
- 避免某些 PowerShell 5.1 表达式/返回行为造成问题；
- SeriesId 去重逻辑改为显式集合。

---

## 阶段 5：首轮批量 dry-run，出现 38 个 ITEM_NOT_FOUND

### 结果

```text
Targets from run log: 243
NFO missing: 0
Jellyfin item missing: 38
Episode numbers need refresh: 108
Episode numbers already correct: 97
```

243 个目标 NFO 全部存在，但只能直接找到 205 个 Jellyfin Episode。

38 个找不到的条目并非随机，而高度集中在此前被 Jellyfin 错认成同一集的文件中，例如：

- 幼女战记（2017）多集；
- 上伊那牡丹多集；
- SPY×FAMILY Season 3 后半；
- 葬送的芙莉莲第 2 期部分集数；
- 午夜的倾心旋律部分集数。

### 判断

这些物理文件并没有真的从磁盘或 Jellyfin 数据库消失，更像是被 Jellyfin 折叠成同一 Episode 的 alternate/owned version。

普通 `/Items?IncludeItemTypes=Episode` 查询会把这类版本隐藏掉。

---

## 阶段 6：批量脚本加入 alternate version 查询

### Git 版本 3

Commit：

```text
d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8
```

关键变化：Episode 查询增加：

```text
VideoTypes=VideoFile
```

在 Jellyfin 12 中，这会让 Items 查询把 owned/alternate 视频一起返回，从而可以继续按真实物理路径匹配。

### 新 dry-run

```text
Targets from run log: 243
Episode items returned by Jellyfin: 676
NFO missing: 0
Jellyfin item missing: 0
Episode numbers need refresh: 125
Episode numbers already correct: 118
```

### 结论

**已证实：** 之前 38 个 `ITEM_NOT_FOUND` 是查询折叠造成的，不是媒体文件消失。

243 个目标现在全部可以唯一定位。

进一步检查发现，本轮 243 个目标的 Episode number 实际都已经正确；125 个“need refresh”真正需要改的是 Season number。脚本输出中的 `Episode numbers need refresh` 只是早期命名不够准确。

---

## 阶段 7：正式 Apply，230/243 完整成功

### 运行摘要

```text
Targets from run log: 243
Episode items returned by Jellyfin: 676
NFO missing: 0
Jellyfin item missing: 0
Episode numbers need refresh: 125
Episode numbers already correct: 118

Episode refresh requests queued: 125
Episode refresh pending: ... -> 0

Series to refresh: 26
...
Finished.
OK: 230
Not OK: 13
```

### 成功部分

230 个目标最终同时满足：

- `IndexNumber` 正确；
- `ParentIndexNumber` 正确；
- `SeasonId` 指向目标 Season；
- `SeasonName` 与目标 Season 一致。

这意味着 NFO + Episode FullRefresh + Series FullRefresh 的主方案对绝大多数真实媒体库条目成立。

### 唯一失败组

剩余 13 个全部是：

```text
Fate/strange Fake S01E01-S01E13
```

这些 Episode 的数字已经全部成功修正：

```text
ParentIndexNumber = 1
IndexNumber       = 1..13
```

但：

```text
SeasonId = 空
```

而 Series 下没有 Season 1 对象可供重挂。

同一作品的 Special S00E01 可以正常挂到 Specials，因此不是整个 Series 都失效。

---

## 阶段 8：尝试用 /Library/Media/Updated 创建 Fate Season 1，失败

### 脚本

`experiments/jellyfin12-nfo-refresh/04-fate-filesystem-refresh.ps1`

### 当时假设

报告 Fate Series 目录发生 `Modified`：

```text
POST /Library/Media/Updated
```

可能会触发一次接近文件系统重新扫描的结构性处理，从而让 Jellyfin 看到已经是 S01 的 13 集并创建 Season 1。

### 实际结果

接口返回成功，但 36 次、每次 5 秒的轮询中始终：

```text
Season 1 not found yet.
```

180 秒后失败。

### 后续源码核对

`/Library/Media/Updated` 实际只会：

```text
ReportFileSystemChanged(path)
    -> FileRefresher
    -> 找到已有 BaseItem
    -> item.ChangedExternally()
    -> QueueRefresh(...)
```

它不是“重建这个目录的媒体层级”。

### 结论

**已推翻：** “`/Library/Media/Updated` 可以作为结构性目录重扫 API”的假设。

这次失败不是再多等一会就会成功；它本质上只是换入口再次排队已有 Item 的 metadata refresh。

---

## 当前未解决问题：为什么 Fate 的 Series 刷新看不见 S01E01-S01E13

Jellyfin `SeriesMetadataService.CreateSeasonsAsync()` 的源码逻辑本来能够：

1. 找到 Series 的 Episode；
2. 收集 `ParentIndexNumber`；
3. 如果存在 S1 Episode 但没有 Season 1，则创建 Season 1；
4. 给 Episode 写入正确 `SeasonId`。

Fate 的 13 集已经有 `ParentIndexNumber=1`，但 Series FullRefresh 多次仍不创建 Season 1。

因此当前最重要的问题不再是 NFO 是否生效，而是：

> SeriesMetadataService 在执行季重建时，为什么没有把这 13 个 Episode 当成当前 Series 的可见子项？

目前有三个候选解释，尚未定论：

1. 这 13 集仍是 owned/alternate items，批量脚本通过 `VideoTypes=VideoFile` 能看到，但 Series 内部查询默认过滤掉；
2. Episode 的 `SeriesId` 仍正确，但 `SeriesPresentationUniqueKey` 已与当前 Series 不一致，导致 Series 的递归查询看不到；
3. 上述关系都正常，则可能是 Jellyfin 12 的 `CreateSeasonsAsync()` 还有另一个未覆盖的边界问题。

---

## 下一步：只读 Fate 诊断

脚本：

```text
experiments/jellyfin12-nfo-refresh/05-fate-readonly-diagnosis.ps1
```

状态：**尚未运行。**

它只读取，不刷新、不改数据库、不写 NFO，目标是同时比较：

- `/Shows/{SeriesId}/Seasons` 能看到哪些 Season；
- `/Shows/{SeriesId}/Episodes` 能看到哪些 Episode；
- 每个 Fate 目标 Item 用普通 `/Items?Ids=` 是否可见；
- 加 `VideoTypes=VideoFile` 后是否才可见；
- 13 集是否 `VisibleInSeries`；
- `SeriesId` 是否为空或错误；
- 原来的 Season 2026 对象是否仍存在。

拿到这份只读结果后，再决定是否需要：

- 真正的 `/Library/Refresh`；
- 只重建 Fate 这个 Series；
- 或继续定位 Jellyfin 上游的 Series/alternate-version 边界问题。

---

## 已证实 / 已推翻 / 待验证总表

### 已证实

- Jellyfin 12 Episode FullRefresh 会读取 NFO 中显式 `<season>` 并更新 `ParentIndexNumber`。
- 目标 Season 已存在时，Series FullRefresh 可以重新挂接 `SeasonId` / `SeasonName`。
- 普通 Items 查询会漏掉部分 alternate/owned Episode；`VideoTypes=VideoFile` 可以把这些物理视频重新纳入。
- 本轮 243 个目标中已有 230 个通过自动批量流程完整修复。

### 已推翻

- API Key 场景可直接用 `GET /Items/{id}` 作为单条目读取接口。
- 首轮 38 个 `ITEM_NOT_FOUND` 表示媒体文件消失。
- `/Library/Media/Updated` 等价于结构性目录重扫。
- 只要等待更久，Fate Season 1 就会自然创建。

### 待验证

- Fate 13 集是否全部是 owned/alternate items。
- Fate 13 集是否对 `/Shows/{SeriesId}/Episodes` 不可见。
- Fate Episode 的 `SeriesPresentationUniqueKey` 是否已经与 Series 分裂。
- 旧 Season 2026 是否仍存在并影响当前季结构。

## 隐私与原始结果

原始 `jellyfin_tv_nfo_refresh_log.csv` 不提交到公开仓库，因为包含完整本机媒体路径和媒体库清单。

本存档只保留：

- 作品名；
- 季/集目标；
- Jellyfin Item/Series/Season ID；
- 成功/失败统计；
- 必要的状态变化；
- 不可变 Git commit SHA。

因此足以复现调查逻辑，又不公开本机目录结构。