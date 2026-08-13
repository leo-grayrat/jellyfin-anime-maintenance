# Jellyfin 12 TV 动画统一审计导出设计

日期：2026-08-13

## 背景

当前 TV 动画维护已经确认存在两类长期问题，后续不能再只围绕其中一类推进：

1. **结构正确性**：季号/集号、Season 挂接、不同 Episode 被错误组织成 `LocalAlternateVersion`。
2. **元数据正确性**：Series / Episode 标题、简介、Provider ID、海报/分集图等没有正确获取，或仍停留在字幕组文件名残片。

前一阶段已经为 243 个 correction targets 生成并实机验证 canonical view：显式 `SxxEyy - <原文件名>` 的 hardlink 可以规避已确认的路径解析 / LocalAlternateVersion 问题；第二次 dry-run 也验证了 243/243 可复用。

但这不代表 TV 库元数据已经健康。典型遗留包括：

- 《金牌得主》部分 Episode 名仍是 `Medalist`、`Medalist[S2`；
- 《Fate/strange Fake》存在类似 `[晚街与灯` 的截断标题，同时还有错误 alternate group；
- 《君のことが大大大大大好きな100人の彼女 第3期》已经出现正确 S03Exx 和部分 Series Provider ID，但 Series / Episode 元数据仍明显不完整；
- TV 库中还有 SP / NCOP / NCED / Fonts / CDs 等 extras，需要单独标记和后续人工分类，而不能与正片 correction target 混为一谈。

因此，下一阶段先建立一份统一、只读、可重复的 TV audit export。以后结构问题和元数据问题都从同一份事实快照出发，不再靠上下文记忆维持问题列表。

## 当前范围

### 包含

只处理 Jellyfin `CollectionType = tvshows` 的媒体库：

- Series
- Season
- Episode
- 正常可见 Episode
- 作为 local alternate / owned item 隐藏但仍存在的 Episode
- TV 媒体库根目录下的本地视频文件与同名 NFO 状态
- TV library 的元数据 provider 配置

### 暂不包含

- `CollectionType = movies` 的剧场版媒体库；
- 剧场版目录中实际属于特典、短片、OVA 等内容；
- 对 Jellyfin metadata / database 的写入；
- NFO 改写；
- Refresh / Identify / Delete / Merge 等操作。

剧场版问题继续冻结，待 TV 动画部分完成后单独处理。

## 关于 `EnableInternetProviders`

升级后的 library export 中可见 `EnableInternetProviders = false`，但这不能直接解释为“远程元数据提供器已经关闭”。当前实际 provider 配置应以各 `TypeOptions` 为准，例如 Series / Season / Episode 下仍列有 `TheMovieDb`、`The Open Movie Database` 等 `MetadataFetchers` / `ImageFetchers`。

因此统一审计：

- 保留 `EnableInternetProviders` 原始值用于历史对照；
- 同时完整导出 `TypeOptions`；
- 不把 `EnableInternetProviders = false` 单独判定为 metadata failure；
- 重点调查“provider 配置仍存在，但具体 Series / Episode 为什么没有得到完整 metadata”。

## 方案选择

采用新增专用脚本，而不是继续扩张现有通用导出脚本：

```text
scripts/export_jellyfin_tv_audit_12.ps1
```

现有：

```text
scripts/export_jellyfin_library_12.ps1
```

继续保留为快速、通用的 Series / Season / Episode / Movie JSON 导出工具。

这样可以避免为了审计需求把通用脚本变成一个越来越重、越来越难理解的工具，也不会破坏已经写进 `docs/library-export.md` 的旧用法。

## 输出文件

默认输出：

```text
%USERPROFILE%\Desktop\jellyfin-tv-audit-export.json
```

允许使用 `-Output` 指定其他路径。

输出 JSON 顶层建议为：

```text
SchemaVersion
ExportedAt
Server
TvLibraries
NormalItems
ExpandedEpisodes
FilesystemVideos
```

### `SchemaVersion`

固定 schema 版本，初版为 `1`。以后字段扩展时允许审计脚本判断兼容性。

### `Server`

至少包含：

- Jellyfin Version
- ProductName（若 API 返回）
- ServerName（若 API 返回）

不保存 API Key。

### `TvLibraries`

仅导出 `CollectionType = tvshows` 的 virtual folders，并保留：

- Name
- ItemId
- Locations
- CollectionType
- LibraryOptions
  - PreferredMetadataLanguage
  - MetadataCountryCode
  - LocalMetadataReaderOrder
  - EnableInternetProviders（仅作原始状态记录）
  - TypeOptions（重点保留各类型 MetadataFetchers / ImageFetchers / 顺序）

可以保留完整 `LibraryOptions`，避免因为预判字段而再次遗漏重要设置。

### `NormalItems`

按 TV library 分别查询，避免混入 movie library。

包含：

- Series
- Season
- Episode

每项至少需要：

- Id
- Type
- Name
- OriginalTitle
- SortName
- Path
- ProviderIds
- Overview
- ProductionYear
- PremiereDate
- DateCreated
- IndexNumber
- ParentIndexNumber
- SeriesId
- SeriesName
- SeasonId
- SeasonName
- ParentId
- MediaSourceCount
- ImageTags / BackdropImageTags 等 API 返回的图片状态

普通 Episode 查询保留 `MediaSources`，以便识别“UI 中一个 Episode 实际挂了多个物理文件”的情况。

### `ExpandedEpisodes`

单独再查询一次 Episode，并加入：

```text
VideoTypes=VideoFile
```

这是此前全局 alternate-group 审计已经在本服务器验证过的 expanded view 方法。它能够把 normally hidden 的 alternate / owned Episode 也取回来。

字段与普通 Episode 尽量保持一致，但无需为了 Series / Season 重复抓两遍非 Episode 项。

这样统一 JSON 可以直接回答：

- Episode 是否 normally visible；
- 是否只在 expanded view 可见；
- 当前 S/E 是什么；
- 是否拥有异常 MediaSourceCount；
- 是否存在“自身 S/E 已正确，但仍被隐藏为别集 local alternate”的状态。

### `FilesystemVideos`

API 只能告诉我们 Jellyfin 已经收录了什么，无法发现“磁盘上存在、Jellyfin 完全没收进去”的文件。因此专用审计导出需要同时读取各 TV library `Locations`。

初版只枚举常见视频扩展名：

```text
.mkv
.mp4
.m4v
.avi
.ts
.webm
```

每个文件记录：

- LibraryName
- LibraryRoot
- Path
- Extension
- Length
- LastWriteTime
- SameNameNfoPath
- SameNameNfoExists

如同名 NFO 存在，则读取一个**轻量 NFO 摘要**：

- season
- episode
- title
- plot
- uniqueid / provider id（若存在）

这里的目的不是让导出器理解所有 NFO 语义，而是能够区分：

- NFO 只有 S/E；
- NFO 已经包含 title / plot；
- NFO 是否存在 Provider ID；
- Jellyfin 当前 Name / ProviderIds 与本地 NFO 是否明显不一致。

如果 PowerShell 5.1 在部分超长字幕组路径上再次暴露 `MAX_PATH` 问题，优先复用仓库已经验证过的 long-path/native helper 思路，而不是跳过这些文件。

## 后续审计分类

这个导出器本身只采集事实，不直接判断或修复。

后续 audit 脚本基于同一 JSON 生成统一问题清单，至少保留以下分类：

- `STRUCTURE_OK`
- `STRUCTURE_WRONG_SEASON_EPISODE`
- `STRUCTURE_HIDDEN_ALTERNATE`
- `METADATA_BAD_TITLE`
- `METADATA_MISSING_PROVIDER_ID`
- `METADATA_MISSING_OVERVIEW`
- `METADATA_MISSING_IMAGE`
- `SERIES_METADATA_INCOMPLETE`
- `FILESYSTEM_NOT_IN_JELLYFIN`
- `REVIEW_EXTRAS`

一个条目可以同时拥有多个问题标签，例如：

```text
Fate S01E08
  STRUCTURE_HIDDEN_ALTERNATE
  METADATA_BAD_TITLE
  METADATA_MISSING_PROVIDER_ID
```

这能避免“修结构时忘记 metadata，修 metadata 时又忘记结构”。

## 三个代表病例

统一审计建立后，只选择少量根因不同的代表病例做写操作实验：

1. 《金牌得主》：S/E 已经可确定，但 Episode title 仍是文件名残片；
2. 《Fate/strange Fake》：错误 alternate group 与错误 title 同时存在；
3. 《君のことが大大大大大好きな100人の彼女 第3期》：S03Exx 已正确、Series 有部分 Provider ID，但 Series / Episode metadata 仍未完整获取。

目标是验证“结构正确以后，metadata 应如何可靠补齐”，而不是继续为每部动画单独发明修复脚本。

## 与 canonical view 的关系

当前 243-target canonical view builder 已经通过真实 Apply + 第二次 243/243 reusable 验证，应暂时冻结，不把 metadata 修复逻辑塞进去。

统一流程为：

```text
原始 TV 动画
    ↓
TV audit export（只读事实快照）
    ↓
统一 audit 分类
    ├─ 结构问题 → canonical view / 已验证的结构路线
    ├─ metadata 问题 → Identify / Refresh / NFO 策略实验
    └─ extras → REVIEW_EXTRAS，后续单独处理
    ↓
结构和 metadata 两条路线都验证后
    ↓
再扩展完整 TV canonical view
```

## 安全边界

`export_jellyfin_tv_audit_12.ps1` 必须满足：

- 只使用 GET 请求；
- 不调用 refresh / delete / update API；
- 不写媒体文件；
- 不写 NFO；
- 不写 Jellyfin 数据库；
- 唯一写操作是生成用户指定的 JSON 导出文件；
- API Key 不进入输出 JSON；
- 请求失败时直接停止，不生成“看起来成功但内容为空”的结果。

## 验证标准

实现完成后，至少验证：

1. Windows PowerShell 5.1 parser 检查通过；
2. 输出中没有 movie library；
3. TV library 数量与 `/Library/VirtualFolders` 中 tvshows 数量一致；
4. normal Episode 数量与当前 API 普通视图一致；
5. expanded Episode 数量不少于 normal Episode，并能再次看到已知 hidden alternate 案例；
6. 文件系统枚举能覆盖已知超长字幕组目录；
7. 输出能同时展示 Medalist / Fate / 100 女友第三期的结构与 metadata 字段；
8. API Key 不出现在导出文件；
9. 脚本运行前后媒体文件、NFO、Jellyfin metadata 均不发生变化。
