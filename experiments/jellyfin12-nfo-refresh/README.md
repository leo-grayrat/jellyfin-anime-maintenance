# Jellyfin 12 NFO 刷新实验存档

这里保存 2026-08-11 调查 Jellyfin 12 NFO 季号修正与 alternate-version 残留关系时使用的一次性脚本和脱敏运行结果。

**这里不是正式工具入口。** 当前正式批量工具仍是：

```text
scripts/refresh_jellyfin_nfo_12.ps1
```

完整早期调查时间线见：

```text
docs/history/2026-08-11-jellyfin12-nfo-refresh.md
```

## 为什么要单独存档

这一轮调查先后出现了 API 读取方式错误、Episode 与 Series 两阶段刷新、alternate version 查询折叠、Fate 缺失 Season 1，以及最后发现的全库 stale alternate-group 问题。若只保留最终脚本，很容易把“当时为什么这样改”“哪些假设已经被推翻”丢掉。

因此这里同时保存：

- 未进入正式工具的一次性实验脚本；
- 每次实际运行的关键输出；
- 已进入 Git 历史的批量脚本版本对应 commit；
- 已证实、已推翻和仍待验证的结论。

## 一次性实验脚本

| 文件 | 状态 | 用途 |
| --- | --- | --- |
| `01-single-episode-refresh-broken.ps1` | 已运行，失败 | 最早的单集测试；错误使用 `GET /Items/{id}`，API Key 场景返回 HTTP 400 |
| `02-single-episode-refresh.ps1` | 已运行，成功 | 改用 `/Items?Ids=...` 读取状态，验证 Episode FullRefresh 会读取 NFO 的 `<season>` |
| `03-series-relink.ps1` | 已运行，成功 | 验证 Series FullRefresh 会把 Episode 从旧 SeasonId 重新挂到已有目标 Season |
| `04-fate-filesystem-refresh.ps1` | 已运行，失败 | 尝试用 `/Library/Media/Updated` 促使 Fate 创建缺失 Season 1；180 秒内没有创建 |
| `05-fate-readonly-diagnosis.ps1` | 已运行，只读 | 证实 Fate S01E01-S01E13 全部是 expanded 查询才可见的 owned/alternate 项，并且对 Series 不可见 |
| `06-fate-alternate-group-diagnosis.ps1` | 已运行，只读 | 证实 Fate 的 S00E01 与 S01E01-S01E13 共 14 个文件被合并成同一个 alternate group，唯一 visible owner 是 S00E01 |
| `07-fate-split-alternate-group.ps1` | **冻结，未运行 Apply** | Fate 专用拆组方案；在发现该问题并非 Fate 特例后停止作为下一步入口，避免逐作品打补丁 |
| `08-global-alternate-group-audit.ps1` | 已运行，只读 | 对全部 243 个 NFO correction target 审计 alternate groups，确认问题广泛存在 |
| `09-medalist-alternate-split-pilot.ps1` | **尚未运行** | 选择金牌得主一个 8-source、全成员已知、目标 S/E 全不同的错误组，最小化测试官方拆组 API；默认 dry-run |

脚本中的 API Key 均使用参数传入；历史结果中的本机媒体绝对路径已脱敏。

## 正式批量脚本版本

批量脚本本身已经由 Git 保存完整版本，因此这里不复制几百行相同源码，而用不可变 commit SHA 索引：

| 版本 | Commit | 变化 | 对应结果 |
| --- | --- | --- | --- |
| 批量初版 | `c7c8042499bd17968f65369f5064c142fba23abf` | 新增 Jellyfin 12 批量 Episode FullRefresh → Series FullRefresh 流程 | 首轮 dry-run 暴露 38 个 `ITEM_NOT_FOUND` |
| 加固版 | `bc478d933fec66f75693fdd48210f4ff19b7dbeb` | 修正 PowerShell 空值/返回等边界问题 | 作为后续版本基础 |
| alternate version 查询版 | `d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8` | Episode 查询增加 `VideoTypes=VideoFile`，让 owned/alternate 视频也参与路径匹配 | 243/243 全部找到；正式 Apply 表面得到 230 OK / 13 Fate 失败 |

注意：后续全局 alternate audit 已证明，上述“230 OK”只能解释为这些 expanded item 的 S/E 与 SeasonId 验收通过，**不能解释为 Jellyfin UI 的 Episode / alternate-version 关系已经正确**。

要查看某个批量版本，直接使用 Git：

```powershell
git show c7c8042499bd17968f65369f5064c142fba23abf:scripts/refresh_jellyfin_nfo_12.ps1
git show bc478d933fec66f75693fdd48210f4ff19b7dbeb:scripts/refresh_jellyfin_nfo_12.ps1
git show d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8:scripts/refresh_jellyfin_nfo_12.ps1
```

## 运行结果

`results/` 中保存的是脱敏后的关键输出，不保存含完整本机媒体路径的原始 CSV。

顺序如下：

1. `01-single-episode-400.txt`：最早读取 API 选错，HTTP 400。
2. `02-single-episode-success.txt`：SPY×FAMILY S03E07 的 `ParentIndexNumber` 从 1 变成 3，但 SeasonId 暂时仍指向第 1 季。
3. `03-series-relink-success.txt`：刷新 Series 后，SeasonName/SeasonId 一并改到第 3 季。
4. `04-batch-dryrun-missing-38.txt`：243 个目标中有 38 个按普通 Episode 查询找不到。
5. `05-batch-dryrun-all-found.txt`：加入 expanded/alternate 查询后 243/243 全部找到，125 个需要 Episode 刷新。
6. `06-batch-apply-230-of-243.txt`：正式 Apply 后 per-item 验收 230/243 通过，13 个 Fate 因目标 Season 不存在失败。
7. `07-fate-filesystem-refresh-failed.txt`：`/Library/Media/Updated` 没有创建 Fate Season 1。
8. `08-fate-readonly-diagnosis-owned-items.txt`：证实 Fate 13 个正片均为 normal 查询不可见、expanded 查询可见、Series 不可见的 owned/alternate 项。
9. `09-global-alternate-audit.txt`：全局审计确认 21 个 alternate group 接触 correction targets，其中 20 个明确跨不同 S/E 错误合并；177/243 个 correction targets 位于这些 group 中。

## 当前结论

截至目前已经实际验证：

- Jellyfin 12.0 的 Episode FullRefresh 会尊重 episode NFO 中显式 `<season>`；
- 目标 Season 已存在时，Series FullRefresh 可以重新挂接 `SeasonId` / `SeasonName`；
- 普通 `/Items` 查询会隐藏 linked alternate/owned Episode，`VideoTypes=VideoFile` 可以把物理 item 展开；
- expanded item 的季号/集号已经可以被 NFO 修正，但**旧 alternate-version 关系不会因此自动解除**；
- Fate 不是特例：全局审计中 243 个 correction targets 有 177 个处于某个 alternate group，20/21 个 group 已明确把不同 S/E 错误合并；
- 这解释了为什么诸如金牌得主仍会在 UI 中出现多个“假第二集”，即使每个隐藏物理 item 自己的 `ParentIndexNumber` / `IndexNumber` 已经正确；
- 因此正式批量脚本目前的最终验收条件不充分，后续需要把 alternate-group 一致性纳入验证；
- `/Library/Media/Updated` 不能视为结构性目录重扫，这一假设已被实验推翻。

## 全局审计后的两个重要边界

不能直接对所有 group 盲目拆分并宣布完成：

1. `攻壳机动队` 的 7-source 错误组中，目标实际上包含两个 S01E01、两个 S01E02、两个 S01E03 和一个 S01E04。正确修复应先拆掉跨集错误组，之后可能需要把同一 S/E 的合法多版本重新合并。
2. `幼女战记（2017）` 的错误组共有 25 个 source，但只有 12 个在 correction target 中；另有 13 个未覆盖 source。`名侦探光之美少女！` 也有一个 target + 一个未知 source 的 mixed group。因此全自动修复前必须避免把未知成员当成已知目标处理。

## 当前下一步

不再运行 Fate 专用 `07`。

先运行：

```text
09-medalist-alternate-split-pilot.ps1
```

选择金牌得主是因为该 group：

- 恰好 8 个 source；
- 8 个都属于 correction target；
- 目标分别是 S02E02 到 S02E09，没有同集合法多版本；
- 用户界面中已直接观察到“8 个假第二集”的现象。

该 pilot 在 `-Apply` 前会重新验证 group 当前状态；Apply 只调用 Jellyfin 官方 `DELETE /Videos/{itemId}/AlternateSources` 清理关系，不修改媒体文件/NFO，也不会自动 Series FullRefresh。拆组后先观察这 8 个 item 是否立刻正常可见，以一次只改变一个变量的方式验证根因。
