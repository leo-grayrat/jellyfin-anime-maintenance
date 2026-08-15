# 2026-08-15 720 文件人工判定映射与新视图 Apply 记录

本记录承接此前 Full Canonical View / metadata 调查，但路线已经发生变化：不再继续修补旧 Jellyfin 库中的既有识别状态，而是以真实媒体文件清单为唯一库存事实源，先逐文件人工判定，再由机械执行器建立新视图。

对应主线 Issue：#13。

## 1. 为什么改用 720 文件人工判定

此前旧库中同时存在 Season/Episode 解析错误、hidden alternate、错误标题、provider metadata 不完整、extras 被误识别等问题。继续依赖 Jellyfin 现状反推“真实库存”会把旧识别错误带进下一轮修复。

因此本轮改为：

```text
真实源文件清单
    ↓
逐文件人工/LLM 语义判定
    ↓
显式、可复核的 manifest
    ↓
机械执行器建立硬链接视图
    ↓
全新 Jellyfin library 首次扫描
```

执行器不再解释动画文件名，不推断 Season/Episode，不查询 Jellyfin 旧状态；只执行已经审核过的 `SourcePath / TargetRelativePath / SourceVolume / Status`。

## 2. 主事实源与隐私边界

主事实源为 720 个真实视频文件路径。长文本在 File Library 展开时发生截断，因此最终改为 CSV 后完整读取。

720 行私有清单和判定 manifest 包含本机完整媒体路径，保持在 `inputs/raw/`，不提交公开仓库。

最终清单状态：

- 总行数：720；
- `CONFIRMED`：708；
- `IGNORE`：12；
- 12 个 `IGNORE` 均为 D 盘 Do It Yourself!! 版本；
- Do It Yourself!! 只采用 C 盘 BDRip。

## 3. 已确认的特殊内容判定

本轮明确核定的高风险条目包括：

- U149 `[OVA]`：一个物理文件覆盖 E13-E14；
- 《幼女战记》2017 的 13 个 SP：按已确认的 Season 00 顺序映射；
- Chainsaw Man Compilation 01/02：S00E02/E03；
- Kaguya-sama `Otona e no Kaidan` 01/02：S00E15/E16；
- `ANOTHER WORLD` 01-03：独立三集短篇 Series；
- Clevatess `Tokuten 01-05`：田口和几位监督的对谈、制作花絮，作为 extras；
- GQuuuuuuX `Bonus` 中 `afterimage` / `I don't care` / `Plazma`：MV；
- 剧场版《幼女战记》Theater Manner：按收藏语义保留为电影 extras，而不是强制跟随 TVDB Special。

## 4. LibraryGroup 的真实收藏规则

本轮曾出现一个分类错误：初版 manifest 为《辉夜大小姐想让我告白 大人への階段》新建了 `2025年动画`。

这不是单纯的命名问题，而是没有理解现有收藏结构。

用户实际采用的是两套并存规则：

- **2025 年以前**：本机只保存少数动画，库存稀疏，按季度拆分没有实际意义，因此按年份归档，例如 `2022年动画`；
- **2025 年以后**：本机开始形成成块的季度库存，因此按季度归档，例如 `2025年01月新番 / 04月 / 07月 / 10月`、`2026年01月新番`。

所以：

- Do It Yourself!! 放 `2022年动画` 是有意设计；
- `Otona e no Kaidan` 播出于 2025-12-31，应并入 `2026年01月新番`；
- 用户已在 Apply 后手动完成该移动。

后续 `LibraryGroup` 必须视为结构性判定字段，不能在批量生成 manifest 时随手创造新的年份/季度分组。

## 5. 目标根目录

最终目标根目录为：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
```

`D:\Resource\BangumiLink` 是上层容器，里面还有其他目录，因此不能直接作为本次新动画视图根。

## 6. 执行器

新增：

```text
scripts/apply_anime_decision_manifest.py
```

职责严格限制为：

1. 读取审核后的 CSV；
2. `IGNORE` 行跳过；
3. 检查源文件存在；
4. 检查源盘与目标根同卷；
5. 检查目标相对路径安全且无重复；
6. 若目标已存在，必须确认它与源文件是同一硬链接才允许复用；
7. dry-run 默认不写磁盘；
8. 只有显式 `--apply` 才创建硬链接；
9. Apply 中途失败时，只回滚本次新创建的目标，不修改原始文件。

它不读取 Season/Episode 字段来“纠正”路径，也不解析文件名。

## 7. 真实 Windows 预检与 Apply

用户在真实 Windows 环境运行：

```text
Manifest rows: 720
Active rows:   708
Ignored rows:  12
Missing:       708
Reusable:      0
Mode: DRY-RUN (no filesystem changes)
```

这里 `Missing: 708` 指 708 个目标硬链接尚未存在；源文件若缺失，preflight 会直接报错退出。

随后用户已执行 `--apply`，并在 Apply 完成后手动把《辉夜大小姐想让我告白 大人への階段》移动到 `2026年01月新番`。

由于该手动移动发生在 manifest Apply 之后，当前私有 manifest 中这两行仍需要同步修改，否则再次 dry-run 会把旧的 `2025年动画` 目标视为 `MISSING`。

## 8. 当前未完成的最后文件层验证

现在不要直接创建 Jellyfin 新库。先让 manifest 与用户手动移动后的真实目录重新一致：

1. 将 `Otona e no Kaidan` 两行的 `LibraryGroup` 从 `2025年动画` 改为 `2026年01月新番`；
2. 将对应 `TargetRelativePath` 的第一层同步改为 `2026年01月新番`；
3. 用最终 D 盘根 `D:\Resource\BangumiLink\View` 再跑一次 dry-run；
4. 完成判据是：

```text
Manifest rows: 720
Active rows:   708
Ignored rows:  12
Missing:       0
Reusable:      708
Mode: DRY-RUN (no filesystem changes)
```

只有这个闭环成立，才进入全新 Jellyfin library 的首次扫描。

## 9. Jellyfin 新库的目录层级

不能直接把 `C:\resource\video\anime` 或 `D:\Resource\BangumiLink\View` 整体作为 TV library 的单一 Location。manifest 的第一层是 `LibraryGroup`，例如 `2025年04月新番`、`2026年01月新番`；如果 Jellyfin 从更上一层扫描，这些分组目录可能被当成 Series 层。

正确方式是按 `LibraryGroup` 建库/配置 Location：

- 每个年份/季度分组对应一个 Jellyfin library；
- 如果同一个分组同时存在于 C/D 两盘，则把两个同名分组目录都加入同一个 Jellyfin library；
- 例如 `2025年04月新番` 应同时使用：

```text
C:\resource\video\anime\2025年04月新番
D:\Resource\BangumiLink\View\2025年04月新番
```

- 只存在单盘的分组只添加实际存在的那一个 Location；
- `剧场版` 应继续按 Movie library 处理，不混入 TV library。

## 10. 后续路线

文件层闭环后：

1. 按上面的 `LibraryGroup` 层级创建全新的 Jellyfin libraries，不复用旧库；
2. 让 Jellyfin 做第一次自然扫描；
3. 再导出统一 audit；
4. 只检查新库仍实际存在的问题：Series/Season/Episode、Special、extras、多版本、标题/简介/provider metadata；
5. 不再根据旧库遗留问题预设新库一定需要同样修复。
