# 2026-08-15 基于 manifest 自动重建 Jellyfin 库

对应 Issue：#13。

## 目标

文件层已经通过最终 dry-run 闭环：720 行 manifest 中 708 条为实际整理项、12 条为 `IGNORE`，实际目标全部可复用。

下一步不再手工逐个创建 Jellyfin 库，而是让脚本根据同一份私有 manifest 自动建立最终库。

## 最终库名策略

本阶段不使用 `新视图-`、`测试-` 等临时前缀。

用户的实际流程是：

1. 先删除不再需要的旧 Jellyfin 动画库；
2. 保留已经建立好的新硬链接目录；
3. 由脚本直接按最终 `LibraryGroup` 名称一次性建立新库。

因此库名直接等于 manifest 的 `LibraryGroup`，例如：

- `2022年动画`
- `2025年01月新番`
- `2025年04月新番`
- `2026年01月新番`
- `剧场版`

不先创建临时名称，也不安排第二轮 Rename。

脚本不会删除旧库。如果同名库仍存在但类型或 Locations 与计划不同，preflight 报 `CONFLICT` 并停止；用户先完成旧库清理后再运行即可。

## 自动化规则

新增：

```text
scripts/create_jellyfin_libraries_from_manifest.py
```

脚本从私有 manifest 的 `CONFIRMED` 行生成库计划：

- 按 `LibraryGroup` 聚合；
- `TV_MAIN / TV_EXTRA / TV_SPECIAL / U149_MULTI / ANOTHER_WORLD` → `tvshows`；
- `MOVIE / MOVIE_EXTRA` → `movies`；
- 同一 `LibraryGroup` 如果同时存在 C:/D: 来源，则同一个 Jellyfin library 自动挂两个 Locations；
- C 盘根固定为 `C:\resource\video\anime`；
- D 盘根固定为 `D:\Resource\BangumiLink\View`；
- `IGNORE` 行不参与建库；
- `TargetRelativePath` 第一层必须与 `LibraryGroup` 一致，否则拒绝运行；
- 同一组如果混入 TV 与 Movie bucket，拒绝运行。

默认是 dry-run。显式 `--apply` 后，只创建当前缺失的库。每个库创建时设置 `refreshLibrary=false`，全部创建完后只触发一次全库扫描。

## Provider 策略

建库前通过 Jellyfin `/Libraries/AvailableOptions` 读取当前服务器真实可用 provider，不只依赖代码里的静态假设。

当前用户确认的图片 provider：

- TV Series：`TheMovieDb`、`TheTVDB`；
- Movie：`TheMovieDb`、`TheTVDB`、`The Open Movie Database`、`Embedded Image Extractor`、`Screen Grabber`。

最终策略：

- 普通 metadata：`TheMovieDb` 第一，其余已启用 provider 按 Jellyfin 返回顺序作为后备；
- TV Series 图片：`TheTVDB` → `TheMovieDb`；
- Movie 图片：`TheTVDB` → `The Open Movie Database` → `TheMovieDb` → `Embedded Image Extractor` → `Screen Grabber`。

当前不顺带修改 `PreferredMetadataLanguage` / `MetadataCountryCode`。

## Chainsaw Man 总集篇的语义例外

`Chainsaw Man - The Compilation - 01/02` 当前继续作为 2022 TV Series 的 Season 00，映射 S00E02/E03，因此目录位于 `2022年动画`。

这不是实际发行年份判断。官方资料显示《チェンソーマン総集篇》实际于 2025-09-05 在 ABEMA 先行配信，2025-09-12 起在其他平台配信。用户个人收藏语义更倾向把它视作电影/剧场版一侧，但为了当前 Jellyfin/数据库的 Season 00 识别，决定不再搬动。

以后遇到数据库归属与实际发行时间/收藏语义冲突，必须在映射阶段主动披露，而不能只给出数据库兼容后的结果。

## 安全边界

脚本只管理 manifest 中计划创建的库名，不删除、重命名或修改其他 Jellyfin 库。

如果计划中的库已经存在：

- 名称、类型、Locations 全部一致 → `REUSABLE`；
- 同名但类型或 Locations 不一致 → `CONFLICT`，停止；
- 不存在 → `MISSING`，只有 `--apply` 才创建。

这样即使用户没有完全删干净旧动画库，也不会被脚本静默覆盖。

## 真实 Jellyfin dry-run（2026-08-15）

用户在真实 Jellyfin 实例上运行 dry-run，得到：

```text
Planned libraries: 12
Missing:           12
Reusable:          0
Conflicts:         0
Mode: DRY-RUN (no Jellyfin changes)
```

12 个最终库及路径全部符合预期：11 个 `tvshows` + 1 个 `movies`；`2022年动画`、`2025年01月新番`、`2025年04月新番` 自动跨 C/D 挂双 Location，其余只挂实际存在的盘。

真实 provider 输出：

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

这里暴露出一个真实脚本问题：用户的 Jellyfin 明确返回 `Embedded Image Extractor` 为 Movie 可用图片 provider，但它没有进入最终 `ImageFetchers`。根因不是 provider 不存在，而是 Jellyfin 把它返回为 `DefaultEnabled=false`，旧脚本只对三个远程图片源做显式启用，因此把它过滤掉。

已修正：Movie 的五个已确认图片 provider 现在全部显式启用，并保持上述目标顺序。对应回归测试也改为让 `Embedded Image Extractor` / `Screen Grabber` 在输入中 `DefaultEnabled=false`，确保这类真实服务器状态不会再次被静默过滤。

这次问题的有效验证来自用户真实 Jellyfin dry-run；云端单元测试只保留为代码回归保护，不作为 Jellyfin 行为已经验证的证据。

## 运行方式

为了避免每次命令都重复 API key，可以在当前 PowerShell 会话先设置：

```powershell
$env:JELLYFIN_API_KEY = "<API_KEY>"
```

然后更新仓库并重新 dry-run：

```powershell
git pull
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

只有真实输出中 Movie 图片顺序完整包含：

```text
TheTVDB -> The Open Movie Database -> TheMovieDb -> Embedded Image Extractor -> Screen Grabber
```

且仍为 `Conflicts: 0`，才进入正式 `--apply`。
