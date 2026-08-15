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

## 安全边界

脚本只管理 manifest 中计划创建的库名，不删除、重命名或修改其他 Jellyfin 库。

如果计划中的库已经存在：

- 名称、类型、Locations 全部一致 → `REUSABLE`；
- 同名但类型或 Locations 不一致 → `CONFLICT`，停止；
- 不存在 → `MISSING`，只有 `--apply` 才创建。

这样即使用户没有完全删干净旧动画库，也不会被脚本静默覆盖。

## 元数据与图片 provider 策略

建库不能只创建路径后依赖 Jellyfin 默认 provider 排序。本轮把用户已经确认的 provider 取舍一并写入建库请求。

脚本先通过 Jellyfin 的 `/Libraries/AvailableOptions` 读取当前服务器在 `tvshows` / `movies` 下实际提供的 provider，再生成 `LibraryOptions.TypeOptions`。如果服务器实际返回与用户刚刚确认的 provider 能力不一致，preflight 直接停止，不带着错误假设创建库。

### 普通文字元数据

所有支持 `TheMovieDb` 的媒体类型都把：

```text
TheMovieDb
```

放到 `MetadataFetcherOrder` 第一位。其他当前可用、已启用的 metadata provider 保留在其后。

这对应当前目标：一般标题、简介、年份、演员等优先从 TMDB 获取。

### 电视节目图片

用户确认服务器“图片获取器（电视节目）”只有：

```text
TheMovieDb
TheTVDB
```

因此 Series 图片固定为：

```text
TheTVDB
TheMovieDb
```

即 TVDB 优先，TMDB 降为第二来源。

### 电影图片

用户确认服务器“图片获取器（电影）”为：

```text
TheMovieDb
TheTVDB
The Open Movie Database
Embedded Image Extractor
Screen Grabber
```

因此 Movie 图片固定排序为：

```text
TheTVDB
The Open Movie Database
TheMovieDb
Embedded Image Extractor
Screen Grabber
```

远程图片源优先，本地内嵌图/截图只做末级兜底；TMDB 保留，但不再抢占海报第一优先级。

当前脚本没有擅自修改 `PreferredMetadataLanguage` / `MetadataCountryCode`。本轮只解决 provider 启用与优先级，不顺带改变文字语言偏好。

## 《电锯人 总集篇》的分类语义冲突

本轮补记一个此前没有主动披露、但应该披露的例外。

当前 manifest 把 `Chainsaw Man - The Compilation - 01/02` 映射为 2022 TV Series 的 `S00E02 / S00E03`，因此物理视图归在 `2022年动画`。

但这不代表总集篇在 2022 年发行。官方《链锯人》页面显示，《チェンソーマン総集篇》是在 **2025-09-05** 于 ABEMA 先行配信，**2025-09-12** 起在其他平台配信，随后还有 AT-X 放送。官方页面将其称为“总集篇”，并不是 2022 TV 本放送内容。

用户个人收藏语义更倾向把这种长篇总集内容视作电影/剧场版一侧；但当前为了让 Jellyfin 按已经核定的 TV Series Special 编号识别，最终接受其继续挂在 2022 Series / Season 00 下，不再为此重新搬动。

以后这类“数据库归属与实际发行年份/收藏语义不同”的条目，必须在映射阶段主动披露，而不能只给出最终数据库编号。

## 运行方式

先更新仓库并准备 API key：

```powershell
git pull
$env:JELLYFIN_API_KEY = "<API_KEY>"
```

在用户删除旧动画库之后，先做一次 dry-run：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

Dry-run 除了列出 12 个计划库、Locations 与 `MISSING / REUSABLE / CONFLICT`，还会把 Jellyfin 当前实际返回并准备写入的 metadata/image provider 顺序打印出来。

确认没有 `CONFLICT`、provider 顺序符合上述规则后，正式创建：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

完成后再次 dry-run，预期所有计划库都变为 `REUSABLE`。
