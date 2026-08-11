# Jellyfin 12 NFO 刷新实验存档

这里保存 2026-08-11 调查 Jellyfin 12 NFO 季号修正行为时使用的一次性脚本和脱敏运行结果。

**这里不是正式工具入口。** 当前正式批量工具仍是：

```text
scripts/refresh_jellyfin_nfo_12.ps1
```

完整调查时间线见：

```text
docs/history/2026-08-11-jellyfin12-nfo-refresh.md
```

## 为什么要单独存档

这一轮调查先后出现了 API 读取方式错误、Episode 与 Series 两阶段刷新、alternate version 折叠、Fate 缺失 Season 1 等不同问题。若只保留最终脚本，很容易把“当时为什么这样改”“哪些假设已经被推翻”丢掉。

因此这里同时保存：

- 未进入正式工具的一次性实验脚本；
- 每次实际运行的关键输出；
- 已进入 Git 历史的批量脚本版本对应 commit；
- 当前仍未解决的 Fate/strange Fake 特例。

## 一次性实验脚本

| 文件 | 状态 | 用途 |
| --- | --- | --- |
| `01-single-episode-refresh-broken.ps1` | 已运行，失败 | 最早的单集测试；错误使用 `GET /Items/{id}`，API Key 场景返回 HTTP 400 |
| `02-single-episode-refresh.ps1` | 已运行，成功 | 改用 `/Items?Ids=...` 读取状态，验证 Episode FullRefresh 会读取 NFO 的 `<season>` |
| `03-series-relink.ps1` | 已运行，成功 | 验证 Series FullRefresh 会把 Episode 从旧 SeasonId 重新挂到已有的目标 Season |
| `04-fate-filesystem-refresh.ps1` | 已运行，失败 | 尝试用 `/Library/Media/Updated` 促使 Fate 创建缺失的 Season 1；180 秒内没有创建 |
| `05-fate-readonly-diagnosis.ps1` | 已运行，只读 | 证实 Fate S01E01-S01E13 全部是 expanded 查询才可见的 owned/alternate 项，并且对 Series 不可见 |
| `06-fate-alternate-group-diagnosis.ps1` | **尚未运行** | 只读扫描正常可见 Episode 的 `MediaSources`，反向找出每个 Fate 隐藏 Episode 挂在哪个 visible owner / alternate group 下 |

脚本中的 API Key 均使用参数传入；历史结果中的本机媒体绝对路径已脱敏。

## 正式批量脚本版本

批量脚本本身已经由 Git 保存完整版本，因此这里不复制几百行相同源码，而用不可变 commit SHA 索引：

| 版本 | Commit | 变化 | 对应结果 |
| --- | --- | --- | --- |
| 批量初版 | `c7c8042499bd17968f65369f5064c142fba23abf` | 新增 Jellyfin 12 批量 Episode FullRefresh → Series FullRefresh 流程 | 首轮 dry-run 暴露 38 个 `ITEM_NOT_FOUND` |
| 加固版 | `bc478d933fec66f75693fdd48210f4ff19b7dbeb` | 修正 PowerShell 空值/返回等边界问题 | 作为后续版本基础 |
| alternate version 版 | `d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8` | Episode 查询增加 `VideoTypes=VideoFile`，让 owned/alternate 视频也参与路径匹配 | 243/243 全部找到；正式 Apply 得到 230 OK / 13 Fate 失败 |

要查看某个批量版本，直接使用 Git：

```powershell
git show c7c8042499bd17968f65369f5064c142fba23abf:scripts/refresh_jellyfin_nfo_12.ps1
git show bc478d933fec66f75693fdd48210f4ff19b7dbeb:scripts/refresh_jellyfin_nfo_12.ps1
git show d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8:scripts/refresh_jellyfin_nfo_12.ps1
```

## 运行结果

`results/` 中保存的是脱敏后的关键控制台输出，不保存原始 `jellyfin_tv_nfo_refresh_log.csv`，因为原 CSV 含完整本机媒体路径和媒体库清单。

顺序如下：

1. `01-single-episode-400.txt`：最早读取 API 选错，HTTP 400。
2. `02-single-episode-success.txt`：SPY×FAMILY S03E07 的 `ParentIndexNumber` 从 1 变成 3，但 SeasonId 暂时仍指向第 1 季。
3. `03-series-relink-success.txt`：刷新 Series 后，SeasonName/SeasonId 一并改到第 3 季。
4. `04-batch-dryrun-missing-38.txt`：243 个目标中有 38 个按普通 Episode 查询找不到。
5. `05-batch-dryrun-all-found.txt`：加入 alternate version 查询后 243/243 全部找到，125 个需要刷新。
6. `06-batch-apply-230-of-243.txt`：正式 Apply 后 230/243 完整成功，剩余 13 个全部属于 Fate/strange Fake S01E01-S01E13。
7. `07-fate-filesystem-refresh-failed.txt`：`/Library/Media/Updated` 没有创建 Fate Season 1。
8. `08-fate-readonly-diagnosis-owned-items.txt`：证实 13 个 Fate 正片均为 normal 查询不可见、expanded 查询可见、Series 不可见的 owned/alternate 项；SeriesId 正确，SeasonId 为空。

## 当前结论

截至目前已经实际验证：

- Jellyfin 12.0 的 Episode FullRefresh 会尊重 episode NFO 中显式 `<season>`；
- Episode 的 `ParentIndexNumber` 修正后，若目标 Season 对象已经存在，Series FullRefresh 可以正确更新 `SeasonId` / `SeasonName`；
- 普通 `/Items` 查询可能折叠此前被识别成同一集的 alternate/owned 视频，`VideoTypes=VideoFile` 能把这些物理视频重新纳入查询；
- 批量流程对本轮 243 个目标中的 230 个已完整生效；
- Fate/strange Fake 的 S01E01-S01E13 已经得到正确季号和集号，但 13 个条目全部被 owned/alternate 关系隐藏，因此 `/Shows/{SeriesId}/Episodes` 只看得到 S00E01；
- 这 13 个条目的 `SeriesId` 都正确，所以问题已经从 NFO / SeriesId 缩小到 Jellyfin 的 alternate/owned grouping state；
- 旧 Season 2026 对象已经不存在，而 Season 1 没有被创建；
- `/Library/Media/Updated` 不能视为“强制重新构建目录层级”的 API，这个假设已经被实验推翻。

下一步运行 `06-fate-alternate-group-diagnosis.ps1`。它只读取 `MediaSources`，目标是找出 13 个隐藏条目分别挂在哪些正常可见的 owner item 下，以及这些 owner 是否属于同一个或多个 alternate group。确认关系图之后，再决定是否使用 Jellyfin 官方 `DELETE /Videos/{itemId}/AlternateSources` 拆分错误关系。