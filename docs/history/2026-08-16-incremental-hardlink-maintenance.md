# 2026-08-16 新下载动画的增量硬链接维护

## 背景

项目最初希望通过“一键生成 NFO”长期处理新下载动画。后续确认 NFO 无法稳定解决 Jellyfin 在读取 NFO 前已经形成的错误路径/多版本关系，因此主线已经改为：

1. 原始收藏目录保持不动；
2. 私有 decision manifest 记录 `SourcePath -> WorkTitle / Season / Episode / TargetRelativePath`；
3. Jellyfin 只读取显式 `SxxEyy` 的同盘 hardlink view。

720 文件第一次重建完成后，长期维护需求仍然存在：每周下载新集后，不应重新人工制作一整张 manifest，也不应回到 NFO 路线。

## 新入口

新增：

- `scripts/update_anime_incremental_view.py`
- `tests/test_update_anime_incremental_view.py`

脚本直接以现有私有 manifest 作为状态和事实源。默认扫描：

```text
D:\Bangumi
C:\bangumi
```

目标根保持：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
```

Dry-run：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认 `Needs review: 0` 后执行：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

`--apply` 只处理 manifest 中尚不存在的新视频：先完整 preflight，再创建对应 hardlink，最后原子写回 manifest。创建中途失败时会回滚本轮已经创建的 hardlink。

## 判定方式

脚本不重新解释整个媒体库，也不访问 Jellyfin 元数据来猜集数。它只利用已经人工确认过的 manifest：

- 新视频如果位于一个已经存在的作品源目录下，就继承该作品的 `WorkTitle`、`LibraryGroup` 和目标 Season 目录；
- 文件名显式包含 `SxxEyy` 时直接使用；
- 否则从该作品既有 manifest 行推导“源文件集数 -> 逻辑 Episode”的偏移关系；
- 历史上只出现过 extras 的子目录会被视为非正片区域，不自动把其中数字当 Episode；
- 无法高置信判定的新视频只输出 `[REVIEW]`，且存在任何 REVIEW 时拒绝 `--apply`。

它目前的目标是“同一批正在追的作品继续出新集”这一高频场景。下一季度出现全新作品目录时，第一集仍需先建立一次明确映射，之后脚本即可继续学习该作品的既有关系。

## 真实例外：World Is Dancing 换字幕组

原有 `Studio GreenTea` 版本停止更新，后续改用 Nix-Raws，并且 Nix-Raws 自己多套了一层字幕组目录，例如：

```text
D:\Bangumi\2026\2026-07\ワールド イズ ダンシング\
  [Nix-Raws] World Is Dancing S01 [CATCHPLAY WEB-DL 1080p AVC AAC][SC_TC]\
    [Nix-Raws] World Is Dancing S01E05 [CATCHPLAY WEB-DL 1080p AVC AAC][SC_TC].mkv
```

增量脚本按“已知作品根目录”匹配，因此允许这层新子目录；文件名又显式包含 `S01E05`，可直接生成 Season 01 / Episode 05 的目标 hardlink，不依赖旧字幕组文件名格式。

## 百女友第三季元数据异常

新库首次稳定后发现：《君のことが大大大大大好きな100人の彼女》第三季能匹配 Series/Season 封面，但现有各集没有正常取得标题和简介。

截至 2026-08-16，TheTVDB 的 Aired Order 已经明确存在 Season 3；S03E01-S03E04 有标题和日文简介，S03E05-S03E06 也已经有对应 Episode 条目。因此至少不能解释为“TVDB 根本没有第三季”。

同时，本项目此前已经记录过一次 provider 修正传播失败：用户明确纠正了“TMDB 擅长中文图片、TVDB 对 TV 季/集结构更有用”的关系后，自动建库脚本最终仍一度保留 `TheMovieDb -> TheTVDB` 的 TV metadata 顺序。

因此当前强怀疑是：文件已经正确映射为 `S03E01+`，但 Jellyfin 首轮刮削优先使用了与 Season 3 结构不一致或信息不足的 provider，导致 Episode 级标题/简介没有落下来，而 Series/Season 图片仍能取得。

这只是基于数据库现状和既有 provider 配置的解释，尚未在当前 Jellyfin 实例上逐请求证明。用户不希望为少量残余问题再次大规模重建，因此本轮只记录，后续如需要写针对性修复/刷新脚本，再以这个现象作为测试对象。
