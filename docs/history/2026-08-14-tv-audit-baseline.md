# 2026-08-14 TV 动画统一审计基线

本记录来自 `jellyfin-tv-audit-2026-08-14.json`。这是第一份同时包含 Jellyfin 正常视图、expanded Episode、TV 文件系统视频和同名 NFO 摘要的完整快照。

## 导出结果

Jellyfin：12.0.0。

只统计 `CollectionType = tvshows`：

- TV libraries：11（其中 1 个为 `test`）
- Normal items：637
  - Series：57
  - Season：93
  - Episode：487
- Expanded Episodes：678
- Filesystem videos：678
- Same-name NFOs：245
- NFO summaries：245
- NFO read errors：0

文件系统 678 个视频路径与 expanded Episode 678 个路径一一对应，当前配置进 Jellyfin 的 TV roots 中没有发现“磁盘存在但 expanded Episode 完全不存在”的视频。

`test` 库之外共有 676 个实际 TV 视频 / expanded Episodes。

## 243 个 correction targets 的当前事实

245 个 NFO 中：

- 2 个属于 `test`；
- 243 个属于此前 correction targets，数量与 canonical view 第一阶段完全一致。

这 243 个生产 NFO：

- 243/243 都成功读取；
- 243/243 的 `<season>` / `<episode>` 与 Jellyfin expanded Episode 当前的 `ParentIndexNumber` / `IndexNumber` 完全一致；
- 243/243 的 `title` 为空；
- 243/243 的 `plot` 为空；
- 243/243 没有 provider unique id。

因此可以明确：当前 correction NFO 只负责 S/E，不会用本地 `title` / `plot` 覆盖 Jellyfin 的在线 Episode 元数据。以后出现 `Medalist`、`[晚街与灯`、`[FLsnow`、`Hyakkano` 等错误标题时，不能再归因于这些 correction NFO 写入了错误标题。

## 结构问题基线

Normal Episodes 为 487，expanded Episodes 为 678，相差 191。

排除 `test` 库后：

- hidden / normally invisible Episode：190
- 其中 correction target：157
- hidden 且不属于 correction target：33
- correction targets 中正常 visible：86

也就是说，前一阶段的 243-target canonical view 不是只对应当前 190 个 hidden item。它覆盖了完整的 243 个已确认 S/E 修正目标，其中既有 hidden child，也有当前 normal view 中的 owner / visible item。

33 个非 correction-target hidden item 不应自动并入同一修复规则。它们包含：

- 合法或可能合法的 `v2` / 多版本文件；
- 幼女战记 SP；
- Clevatess 特典 / PV / menu / NCOP 等；
- 100 女友 NCOP / NCED；
- GQuuuuuuX Bonus；
- Precure NCOP/ED 等。

后续统一账本将这些项目标记为 `REVIEW_NON_TARGET_HIDDEN` / `REVIEW_EXTRAS`，不自动修复。

## 标题问题与结构问题确实同时存在

在 243 个 correction targets 中，用一个保守规则检查：

> 同一 Series 内，同一个 Episode `Name` 同时出现在两个或更多不同 S/E 上。

结果：

- 216 / 243 个 correction targets 命中；
- 涉及 21 个 target Series；
- 一共形成 23 个“跨不同 S/E 重复标题”组。

这个标签本身只是审计信号，不代表所有重复标题都必然错误；但在当前库中，它准确覆盖了大量已经肉眼确认的问题，例如整季都显示为同一个标题、字幕组名或作品罗马字名。

这说明后续不能把“结构修复”和“标题修复”拆成互不相干的两个项目：canonical view 负责让物理 Episode 独立，随后 metadata refresh / identify 负责给独立 Episode 补正确标题和其他元数据。

## 代表病例

### 金牌得主

correction targets：13。

- visible：6
- hidden：7
- Provider ID：13/13 有
- Overview：13/13 有
- Primary image：13/13 有
- Episode title 只有 3 种，主要是 `Medalist[S2`、`Medalist`

这类故障最能说明：**已经拿到其他在线元数据，不代表 Episode title 正确。**

### Fate/strange Fake

correction targets：14。

- visible：1
- hidden：13
- Provider ID：0/14
- Overview：0/14
- Primary image：14/14 有
- 14/14 title 都是 `[晚街与灯`

这是“结构问题 + Episode metadata 明显不完整”同时存在的代表。

### 君のことが大大大大大好きな100人の彼女 第3期

correction targets：5。

- 5/5 都 normal visible
- S03E01-S03E05 已正确
- Episode title：5/5 都是 `Hyakkano`
- Episode Provider ID：1/5 有
- Episode Overview：0/5 有
- Episode Primary image：5/5 有

Series 本身：

- IMDb / TMDb / TVDb ID 已存在；
- Overview 已存在；
- Primary image 缺失。

因此这不是“完全没有识别到作品”，而是 Series 半成功、Episode metadata 不完整。

### 名侦探光之美少女！

27 个 correction targets 全部 normal visible，但：

- 27/27 title 都是 `[FLsnow`
- Episode Provider ID：0/27
- Overview：27/27 有
- Primary image：27/27 有

这证明错误标题并不只发生在 hidden alternate 上；即使 Episode 当前已经正常 visible，也可能保留文件名解析残片。

### 葬送的芙莉莲 第二季

correction targets：10。

- visible：2
- hidden：8
- title：10/10 都是 `Sousou no Frieren`
- Provider ID：0/10
- Overview：10/10 有
- Primary image：10/10 有

这也是“部分在线元数据存在，但标题仍回退到文件名/作品名”的代表。

## Series 层总体情况

排除 `test` 后共有 56 个 Series。

按最基础的 Series 健康项检查：ProviderIds、Overview、Primary image，只有一个 Series 有缺项：

- 《君のことが大大大大大好きな100人の彼女 第3期》缺 Primary image。

因此当前主要故障集中在 Episode 层，而不是大规模 Series 身份识别失败。

## 后续推进原则

1. 243-target canonical view builder 保持冻结；它只解决已确认的结构输入问题，不塞入标题修复逻辑。
2. 使用统一 audit ledger 同时保留：
   - `STRUCTURE_HIDDEN_ALTERNATE`
   - `STRUCTURE_NFO_MISMATCH`
   - `METADATA_REPEATED_TITLE_ACROSS_EPISODES`
   - `METADATA_MISSING_PROVIDER_ID`
   - `METADATA_MISSING_OVERVIEW`
   - `METADATA_MISSING_PRIMARY_IMAGE`
   - `SERIES_METADATA_*`
   - `FILESYSTEM_NOT_IN_JELLYFIN`
   - `REVIEW_NON_TARGET_HIDDEN`
   - `REVIEW_EXTRAS`
3. 先用少数代表病例确认 Jellyfin 12 在“结构已经独立”之后应该怎样可靠补齐 Episode metadata，再批量应用。
4. 剧场版继续不进入当前工作范围。
