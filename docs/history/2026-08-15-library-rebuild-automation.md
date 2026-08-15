# 2026-08-15 基于 manifest 自动重建 Jellyfin 库

对应 Issue：#13。

## 目标

文件层已经通过最终 dry-run 闭环：720 行 manifest 中 708 条为实际整理项、12 条为 `IGNORE`，实际目标全部可复用。

下一步不再手工逐个创建 Jellyfin 库，而是让脚本根据同一份私有 manifest 自动建立最终库。

## 最终库名策略

本阶段不使用 `新视图-`、`测试-` 等临时前缀。

用户的实际流程是：

1. 删除不再需要的旧 Jellyfin 动画库；
2. 保留已经建立好的新硬链接目录；
3. 由脚本直接按最终 `LibraryGroup` 名称一次性建立新库。

因此库名直接等于 manifest 的 `LibraryGroup`，例如：

- `2022年动画`
- `2025年01月新番`
- `2025年04月新番`
- `2026年01月新番`
- `剧场版`

不先创建临时名称，也不安排第二轮 Rename。

## 自动化规则

脚本：

```text
scripts/create_jellyfin_libraries_from_manifest.py
```

从私有 manifest 的 `CONFIRMED` 行生成库计划：

- 按 `LibraryGroup` 聚合；
- `TV_MAIN / TV_EXTRA / TV_SPECIAL / U149_MULTI / ANOTHER_WORLD` → `tvshows`；
- `MOVIE / MOVIE_EXTRA` → `movies`；
- 同一 `LibraryGroup` 如果同时存在 C:/D: 来源，则同一个 Jellyfin library 自动挂两个 Locations；
- C 盘根固定为 `C:\resource\video\anime`；
- D 盘根固定为 `D:\Resource\BangumiLink\View`；
- `IGNORE` 行不参与建库；
- `TargetRelativePath` 第一层必须与 `LibraryGroup` 一致，否则拒绝运行；
- 同一组如果混入 TV 与 Movie bucket，拒绝运行。

默认是 dry-run。显式 `--apply` 后，只创建当前缺失的库。每个库创建时设置 `refreshLibrary=false`。

正式 Apply 的顺序：

1. 创建缺失库，但不扫描；
2. 立即重新读取 `/Library/VirtualFolders`；
3. 核对每个库的名称、类型、Locations、`EnableInternetProviders` 与各 Type 的 `MetadataFetchers / MetadataFetcherOrder / ImageFetchers / ImageFetcherOrder`；
4. 只有保存结果全部与计划一致，才触发一次 `/Library/Refresh`；
5. 若回读不一致，脚本报错并停在“库已创建但尚未触发扫描”的状态。

## Provider 策略：最终纠正

最初用户把 TMDB / TVDB 的能力记反，助手也没有在真正写入建库策略前核实，就把错误假设固化进自动建库：图片曾被设置为 TVDB 优先，结果首次扫描得到大量英文海报。

用户在真实 Jellyfin 中进一步确认：

- **TMDB**：有需要的中文海报；
- **TVDB**：海报缺少中文，但对 TV 动画的 Season / Episode 元数据有用。

同时，首次扫描时普通字段已经是中文且正常。因此最终规则不是把两个 provider 全部对调，而是只修图片顺序：

### TV library

- Series / Season / Episode metadata：保持原顺序 `TheMovieDb → TheTVDB`；
- TVDB 继续启用，作为 TMDB 缺少 Season / Episode 信息时的后备来源；
- Series / Season 图片：`TheMovieDb → TheTVDB`；
- Episode 图片：`TheMovieDb → TheTVDB → Screen Grabber`。

### Movie library

- metadata：保持 `TheMovieDb → TheTVDB`；
- 图片：`TheMovieDb → TheTVDB → The Open Movie Database → Embedded Image Extractor → Screen Grabber`。

也就是说：**metadata 不改，只把图片的 TMDB 提到第一。**

当前不顺带修改 `PreferredMetadataLanguage` / `MetadataCountryCode`，因为首次扫描的普通字段已经是正常中文；本轮只修复已确认错误的图片 provider 顺序。

## 首次真实 dry-run 与 Apply

用户在真实 Jellyfin 实例上第一次 dry-run 得到：

```text
Planned libraries: 12
Missing:           12
Reusable:          0
Conflicts:         0
Mode: DRY-RUN (no Jellyfin changes)
```

12 个最终库及路径全部符合预期：11 个 `tvshows` + 1 个 `movies`；`2022年动画`、`2025年01月新番`、`2025年04月新番` 自动跨 C/D 挂双 Location，其余只挂实际存在的盘。

首次真实 provider 输出为：

```text
- tvshows
  Series:
    metadata: TheMovieDb -> TheTVDB
    images:   TheTVDB -> TheMovieDb
  Season:
    metadata: TheMovieDb -> TheTVDB
    images:   TheTVDB -> TheMovieDb
  Episode:
    metadata: TheMovieDb -> TheTVDB
    images:   TheTVDB -> TheMovieDb -> Screen Grabber
- movies
  Movie:
    metadata: TheMovieDb -> TheTVDB
    images:   TheTVDB -> The Open Movie Database -> TheMovieDb -> Screen Grabber
```

这里先暴露了一个脚本问题：`Embedded Image Extractor` 虽然服务器可用，但因 `DefaultEnabled=false` 被过滤掉。之后已经修成 Movie 的五个已确认图片 provider 全部显式启用。

用户随后完成了首次 `--apply`。库创建、文字字段和基本识别正常，但海报大量为英文，由此进一步确认真正的图片源优先级应该是 TMDB 第一。

这次问题的有效验证来自用户真实 Jellyfin；云端单元测试只作为代码回归保护，不作为 Jellyfin 实机行为已经验证的证据。

## 安全重建已有 12 个库

为避免用户再次手工删除 12 个库，脚本新增：

```text
--rebuild-existing
```

该模式只处理 manifest 管理的最终库名，并且删除前必须满足：

- 同名库恰好存在一个；
- CollectionType 与 manifest 计划一致；
- Locations 与 manifest 计划完全一致。

只有被分类为 `REUSABLE` 的库才允许自动删除；任何同名但类型或路径不同的库都会成为 `CONFLICT` 并拒绝删除。

Jellyfin 使用正式的 `DELETE /Library/VirtualFolders?name=...&refreshLibrary=false` 删除 library 配置。这里删除的是 Jellyfin virtual folder，不操作 C/D 盘的硬链接或源媒体文件。

删除完成后，脚本等待这批库从 `/Library/VirtualFolders` 消失，再按相同最终库名和修正后的 provider 顺序重新创建。创建后仍然先回读验证配置，最后才触发一次扫描。

推荐先 dry-run：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --rebuild-existing
```

此时应看到：

```text
Reusable:          12
Conflicts:         0
Rebuild existing:  12 matching libraries would be replaced
Mode: DRY-RUN (no Jellyfin changes)
```

同时 provider 应为：

```text
- tvshows
  Series:
    metadata: TheMovieDb -> TheTVDB
    images:   TheMovieDb -> TheTVDB
  Season:
    metadata: TheMovieDb -> TheTVDB
    images:   TheMovieDb -> TheTVDB
  Episode:
    metadata: TheMovieDb -> TheTVDB
    images:   TheMovieDb -> TheTVDB -> Screen Grabber
- movies
  Movie:
    metadata: TheMovieDb -> TheTVDB
    images:   TheMovieDb -> TheTVDB -> The Open Movie Database -> Embedded Image Extractor -> Screen Grabber
```

确认真实 dry-run 如上后，可一次重建：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --rebuild-existing `
  --apply
```

## Chainsaw Man 总集篇的语义例外

`Chainsaw Man - The Compilation - 01/02` 当前继续作为 2022 TV Series 的 Season 00，映射 S00E02/E03，因此目录位于 `2022年动画`。

这不是实际发行年份判断。官方资料显示《チェンソーマン総集篇》实际于 2025-09-05 在 ABEMA 先行配信，2025-09-12 起在其他平台配信。用户个人收藏语义更倾向把它视作电影/剧场版一侧，但为了当前 Jellyfin/数据库的 Season 00 识别，决定不再搬动。

以后遇到数据库归属与实际发行时间/收藏语义冲突，必须在映射阶段主动披露，而不能只给出数据库兼容后的结果。

## Provider 纠正未被稳定传播：责任记录

用户最初确实曾把 TMDB / TVDB 的优势记反，但随后已经及时明确纠正：

- TMDB 的优势是中文海报；
- TVDB 的优势是 TV 动画的 Season / Episode 元数据。

助手在收到纠正后，一度正确理解为“TV 元数据优先 TVDB、图片优先 TMDB”，随后又因为看到首次扫描中的普通文字字段已经正常，而擅自把 TV metadata 顺序撤回为 `TheMovieDb → TheTVDB`。这个撤回不是用户要求，也不是新的实机证据，而是助手在长上下文中把旧要求、用户纠正和局部运行结果混在一起，造成了状态更新失败。

因此，后续出现“部分 S00 / Special 编号是按 TVDB 人工核对，但扫描时却由 TMDB 优先解释”的不一致，不能简单归因于用户最初记反 provider。用户已经完成纠正；纠正之后仍留下错误配置，属于助手没有把新事实稳定传播到最终实现。

这一点尤其可能影响数据库分歧较大的 Special / Season 00，而普通季度正片因为 TMDB/TVDB 编号往往一致，受影响较小。

本节只记录事实与责任，不在本阶段继续启动新的维护或重建工作。
