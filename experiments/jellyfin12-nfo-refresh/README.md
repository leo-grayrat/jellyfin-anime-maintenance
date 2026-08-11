# Jellyfin 12 NFO 刷新实验存档

这里保存 2026-08-11 至 2026-08-12 调查 Jellyfin 12 NFO 季号修正、alternate-version 错误合并与路径解析问题时使用的一次性脚本和脱敏运行结果。

**这里不是正式工具入口。** 当前正式批量工具仍是：

```text
scripts/refresh_jellyfin_nfo_12.ps1
```

调查记录见：

```text
docs/history/2026-08-11-jellyfin12-nfo-refresh.md
docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md
```

## 为什么要单独存档

这一轮调查先后出现了 API 读取方式错误、Episode 与 Series 两阶段刷新、alternate version 查询折叠、Fate 缺失 Season 1、全库错误 alternate group、数据库关系诊断，以及最终定位到 `YYYY-MM` 路径参与 Episode 解析的问题。若只保留最终脚本，很容易把“当时为什么这样改”“哪些假设已经被推翻”丢掉。

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
| `07-fate-split-alternate-group.ps1` | **冻结，未运行 Apply** | Fate 专用拆组方案；在发现问题并非 Fate 特例后停止使用 |
| `08-global-alternate-group-audit.ps1` | 已运行，只读 | 对全部 243 个 correction target 审计 alternate groups，确认问题广泛存在 |
| `09-medalist-alternate-split-pilot.ps1` | 已运行，未解决 | 调用官方 `DELETE /Videos/{id}/AlternateSources`；未能让 8 个 Episode 独立显示，后来证明该组是 LocalAlternateVersion 而非 LinkedAlternateVersion |
| `10-medalist-local-alternate-db-diagnosis.py` | 已运行，只读 | 直接读取 jellyfin.db，证实金牌得主组为 7 条 LocalAlternateVersion 关系，并确认 OwnerId / PrimaryVersionId / PresentationUniqueKey 状态 |
| `11-python-sqlite-runtime-diagnosis.py` | 已运行，只读 | 定位 `py -3` 实际启动 Python 3.5 + SQLite 3.8.11；改用 Anaconda Python 3.13.5 + SQLite 3.45.3 后数据库只读诊断正常 |
| `12-medalist-e09-remove-readd-pilot.ps1` | 已运行，关键结果 | 原名 S02E09 移出后旧关系消失；原样移回后 Jellyfin 主动重新创建 8-source LocalAlternateVersion group |
| `13-medalist-e09-canonical-name-pilot.ps1` | 已运行，成功 | 同一个视频/NFO 以 `S02E09 - ` 前缀重新加入后保持独立、正常可见且进入 Series |

脚本中的 API Key 均使用参数传入；历史结果中的本机媒体绝对路径应保持脱敏。

## 正式批量脚本版本

批量脚本本身已经由 Git 保存完整版本，因此这里用不可变 commit SHA 索引：

| 版本 | Commit | 变化 | 对应结果 |
| --- | --- | --- | --- |
| 批量初版 | `c7c8042499bd17968f65369f5064c142fba23abf` | 新增 Jellyfin 12 批量 Episode FullRefresh → Series FullRefresh 流程 | 首轮 dry-run 暴露 38 个 `ITEM_NOT_FOUND` |
| 加固版 | `bc478d933fec66f75693fdd48210f4ff19b7dbeb` | 修正 PowerShell 空值/返回等边界问题 | 作为后续版本基础 |
| alternate version 查询版 | `d9ae8ff7f3fa8f18d1fd6f10a662c8ee8b95c3c8` | Episode 查询增加 `VideoTypes=VideoFile`，让 owned/alternate 视频也参与路径匹配 | 243/243 全部找到；正式 Apply 表面得到 230 OK / 13 Fate 失败 |

注意：后续全局 alternate audit 已证明，上述“230 OK”只能解释为 expanded item 的 S/E 与 SeasonId 验收通过，**不能解释为 Jellyfin UI 的 Episode / alternate-version 关系已经正确**。

## 运行结果

`results/` 中保存的是脱敏后的关键输出，不保存 API Key。

当前关键结果包括：

1. `01-single-episode-400.txt`：最早读取 API 选错，HTTP 400。
2. `02-single-episode-success.txt`：SPY×FAMILY S03E07 的 `ParentIndexNumber` 从 1 变成 3，但 SeasonId 暂时仍指向第 1 季。
3. `03-series-relink-success.txt`：刷新 Series 后，SeasonName/SeasonId 一并改到第 3 季。
4. `04-batch-dryrun-missing-38.txt`：243 个目标中有 38 个按普通 Episode 查询找不到。
5. `05-batch-dryrun-all-found.txt`：加入 expanded/alternate 查询后 243/243 全部找到。
6. `06-batch-apply-230-of-243.txt`：正式 Apply 后 per-item 验收 230/243 通过，13 个 Fate 因目标 Season 不存在失败。
7. `07-fate-filesystem-refresh-failed.txt`：`/Library/Media/Updated` 没有创建 Fate Season 1。
8. `08-fate-readonly-diagnosis-owned-items.txt`：证实 Fate 13 个正片均为 normal 查询不可见、expanded 查询可见、Series 不可见的 owned/alternate 项。
9. `09-global-alternate-audit.txt`：全局审计确认 21 个 alternate group 接触 correction targets，其中 20 个明确跨不同 S/E 错误合并；177/243 个 correction targets 位于这些 group 中。
10. 金牌得主数据库只读诊断：确认 owner 存在 7 条 `ChildType=2 (LocalAlternateVersion)`，7 个子项均带 `OwnerId=owner` 与 `PrimaryVersionId=owner`。
11. Python/SQLite 运行时诊断：`py -3` 实际是 Python 3.5.0 + SQLite 3.8.11；Anaconda Python 3.13.5 + SQLite 3.45.3 可以正常读取 Jellyfin 12 schema。
12. `14-medalist-e09-remove-readd-remerged.txt`：旧关系移除后，原名文件重新加入仍被再次合并，证明问题不是单纯历史脏数据。
13. `15-medalist-e09-canonical-name-independent.txt`：同一文件以显式 `S02E09 - ` 前缀重新加入后保持独立，media-source count=1，且通过 Series 可见。

## 当前结论

截至 2026-08-12 已经实际验证：

- Jellyfin 12 的 Episode FullRefresh 会尊重 episode NFO 中显式 `<season>`；
- 目标 Season 已存在时，Series FullRefresh 可以重新挂接 `SeasonId` / `SeasonName`；
- 普通 `/Items` 查询会隐藏 local alternate/owned Episode，`VideoTypes=VideoFile` 可以把物理 item 展开；
- expanded item 的季号/集号可以被 NFO 修正，但旧 alternate-version 关系不会因此自动解除；
- 金牌得主错误组在数据库中确实是 `LocalAlternateVersion`，不是 `LinkedAlternateVersion`；
- 把错误组成员从媒体库移出后，Jellyfin 会删除旧关系；但以**原始路径/原始字幕组文件名**重新加入时，会再次主动创建错误 LocalAlternateVersion group；
- 因此问题不是只修一次 jellyfin.db 就能永久解决的“历史残留”；
- Jellyfin v12.0-rc5 的 TV 多版本分组会先根据 `EpisodePathParser` 对完整路径得到的 season/episode key 分组，再进入后续 NFO metadata 修正；
- 媒体库祖先目录中的 `YYYY-MM`（如 `2026-01`）可能被宽松的 `([0-9]+)-([0-9]+)` episode 规则抢先匹配，从而让同一季度目录里的不同文件得到相同错误 key；
- 对同一个 S02E09，在文件名最前面加入显式 `S02E09 - ` 后，Jellyfin 能建立独立 Episode，说明明确的 `SxxEyy` 命名可以规避当前服务器上的错误分组。

完整因果链与源码位置整理见：

```text
docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md
```

## 仍需注意的边界

不能因此简单把所有文件“一律拆开”：

1. `攻壳机动队` 的错误组中存在同一 S/E 的合法多版本；正确长期方案必须保留同集多版本能力。
2. `幼女战记（2017）`、`名侦探光之美少女！` 等 group 中存在 correction target 之外的未知成员，不能按已有修正规则盲目重建。
3. 当前只用金牌得主 S02E09 完成了 canonical-name 因果实验；在批量应用前仍应把规范视图设计为可验证、可回滚，不直接改原始收藏文件。

## 当前下一步

暂时不继续写数据库直接修复脚本，也不把原始字幕组文件批量重命名。

后续方向改为：**为 Jellyfin 建立一层规范输入视图**，让 Jellyfin 看到明确的 `SxxEyy - <原文件名>`，而原始年度/季度目录和字幕组文件名保持不动。

候选实现方式以同盘硬链接为优先方向，并同步提供同 basename 的 NFO。正式实现稍后单独设计。
