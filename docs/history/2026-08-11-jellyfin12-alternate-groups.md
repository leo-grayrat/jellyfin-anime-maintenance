# 2026-08-11 Jellyfin 12 stale alternate-group 调查记录

本文接续 `2026-08-11-jellyfin12-nfo-refresh.md`，记录在 NFO 季号/集号已经成功写入 Jellyfin item 后发现的第二层问题：**旧的 alternate-version 关系不会随 S/E 元数据修正自动解除。**

## 为什么需要单独记录

此前批量脚本的最终验收主要检查 expanded Episode item 的：

- `ParentIndexNumber`；
- `IndexNumber`；
- `SeasonId`。

正式 Apply 一度得到：

```text
OK: 230
Not OK: 13
```

当时将剩余问题集中到 Fate/strange Fake。但随后 Jellyfin UI 中观察到《金牌得主》第 2 期仍有多个物理文件作为“第 2 集”的 alternate versions 出现。这证明 per-item metadata 正确并不等于 Jellyfin 的 Episode/alternate-version 结构正确。

## Fate 单组诊断

`06-fate-alternate-group-diagnosis.ps1` 证实：

- Fate 的 S00E01 与 S01E01-S01E13 共 14 个物理 Episode item；
- 14 个 item 的 `MediaSources` 都暴露同一组 14 个 source；
- 唯一 normally-visible owner 是 S00E01；
- S01E01-S01E13 虽然各自已经有正确的 S/E 数字，但仍作为该 owner 的隐藏 alternate/owned members。

这说明 Fate Season 1 无法创建并非 NFO 失效，而是 Series 查询根本看不到这 13 个隐藏 members。

## 发现问题并非 Fate 特例

用户随后在 Jellyfin UI 中观察到《金牌得主》第 2 期也存在多个“假第 2 集”。因此停止执行 Fate 专用拆组脚本 `07-fate-split-alternate-group.ps1`，改做全局审计。

## 全局 alternate audit

脚本：

```text
experiments/jellyfin12-nfo-refresh/08-global-alternate-group-audit.ps1
```

结果存档：

```text
experiments/jellyfin12-nfo-refresh/results/09-global-alternate-audit.txt
```

运行摘要：

```text
Targets:                              243
Targets normally visible:             156
Targets hidden but expanded-visible:   87
Targets missing even expanded:          0
Alternate groups touching targets:     21
Definitely wrong groups:               20
Legit same-episode groups:               0
Mixed/unknown groups needing review:    1
Hidden targets without visible owner:    0
```

进一步对 group 成员计数：

- 177 / 243 个 correction targets 位于上述 21 个 alternate group 中；
- 其中 176 个属于 20 个 `DEFINITELY_WRONG` group；
- 另 1 个属于《名侦探光之美少女！》的 mixed/unknown group。

所谓 `DEFINITELY_WRONG` 的判据不是“MediaSourceCount > 1”，而是同一个 alternate group 中出现了不同的目标/current S/E key。例如《金牌得主》group 的 8 个成员已经分别是 S02E02 到 S02E09，却仍被挂在 owner S02E02 下。

## 对此前结论的修正

### 仍然成立

- Jellyfin 12 Episode FullRefresh 会尊重 NFO `<season>` / `<episode>`；
- expanded item 的 S/E 数字确实已经被修正；
- 已存在目标 Season 时，Series FullRefresh 可以修正 SeasonId/SeasonName。

### 需要修正

此前的：

```text
230 OK / 13 Not OK
```

不能再解释为“230 个 Episode 在 Jellyfin 中完全正确”。它只能解释为：

> 230 个 correction target 在 expanded item 层面的 S/E 与 SeasonId 验收通过。

它没有检查这些 item 是否仍被 stale alternate relation 隐藏。

因此正式 `refresh_jellyfin_nfo_12.ps1` 后续需要增加 alternate-group 一致性验收，不能只检查 item metadata。

## 为什么暂时不能全库一键拆

20 个 group 都确定存在跨不同 S/E 的错误关系，但有几个需要额外处理：

- `攻壳机动队`：7 个 source 中有两个 S01E01、两个 S01E02、两个 S01E03、一个 S01E04。拆掉跨集大组后，同 S/E 的两个版本可能应该重新合并成合法 alternate versions。
- `幼女战记（2017）`：错误组有 25 个 source，其中 12 个是本轮正片 correction target，另外 13 个此前未纳入映射。用户提示这些很可能包含迷你动画《ようじょしぇんき》。公开资料显示该迷你动画存在 #00～#12 共 13 个短篇，这与“12 个正片 + 13 个未知 source = 25”高度吻合；但在核对本机文件名之前，不把这 13 个 source 自动映射为该作品。
- `靠死亡游戏混饭吃。`：组中有一个非 target 的 S01E10 source。
- `名侦探光之美少女！`：唯一 mixed group 含一个 S01E11 target 和一个 correction log 外的 S2026E01 source。

所以当前不采用“对所有 group 直接 DELETE 后结束”的方案。

## 当前最小破坏性实验

选择《金牌得主》第 2 期作为 pilot：

- owner：`af564551c864a8892b28736b0de926de`；
- Series：`1e343af25a95b525ae23adc50142693a`；
- 8 个 source 全部在 correction target 中；
- 当前与目标均分别为 S02E02 到 S02E09；
- 没有 unknown source；
- 没有同 S/E 的合法重复版本。

脚本：

```text
experiments/jellyfin12-nfo-refresh/09-medalist-alternate-split-pilot.ps1
```

默认 dry-run。`-Apply` 时唯一的写操作是调用 Jellyfin 官方：

```text
DELETE /Videos/{ownerId}/AlternateSources
```

### Dry-run 结果

结果存档：

```text
experiments/jellyfin12-nfo-refresh/results/10-medalist-alternate-split-pilot-dryrun.txt
```

前置校验通过：

```text
S02E02 normally visible
S02E03 hidden
S02E04 hidden
S02E05 hidden
S02E06 hidden
S02E07 hidden
S02E08 hidden
S02E09 hidden
Hidden members before split: 7 / 8
Owner media-source count: 8
```

8 个成员的 CurrentKey 均已经等于 ExpectedKey，且组内没有未知 source，也没有同一 S/E 的合法多版本。因此该组适合作为第一次真正的 alternate unlink 实验。

## Medalist DELETE pilot：API 成功但结构完全不变

Apply 结果存档：

```text
experiments/jellyfin12-nfo-refresh/results/11-medalist-alternate-split-api-noop.txt
```

实际调用：

```text
DELETE /Videos/af564551c864a8892b28736b0de926de/AlternateSources
```

接口成功返回，但整个轮询周期始终只有 `1 / 8` normally visible；S02E02 的 `MediaSourceCount` 仍为 8，S02E03-S02E09 仍全部隐藏。pilot 按设计没有继续 metadata refresh。

因此已经证实：**该 endpoint 对这类自动识别出来的 Episode local alternate group 不足以完成拆组。重复调用没有意义。**

### 源码层原因

Jellyfin 12 同时维护至少两类 alternate 关系：

- `LinkedAlternateVersion`；
- `LocalAlternateVersion`。

`DELETE /Videos/{id}/AlternateSources` 的实现只遍历 `GetLinkedAlternateVersions(item)`，清除其 `PrimaryVersionId` / `LinkedAlternateVersions`；它没有清除 `LocalAlternateVersion` 链接，也没有清除 `OwnerId`。

而 `Video.MediaSourceCount` 同时计算：

```text
linked versions + local versions + 1
```

本次 DELETE 后 `MediaSourceCount` 仍为 8，与 local alternate 关系仍完整存在完全一致。

更关键的是，Jellyfin 在创建 local alternate item 时会同时：

```text
altVideo.OwnerId = primary.Id
altVideo.SetPrimaryVersionId(primary.Id)
```

普通 Items 查询在 `IncludeOwnedItems=false` 时会过滤掉：

- `PrimaryVersionId != null` 的 alternate item；
- `OwnerId != null` 且不是 legitimate Extra 的 owned item。

所以即使某一层 PrimaryVersion 关系被清掉，只要 stale OwnerId/local relationship 仍在，这些 Episode 仍可能保持隐藏。

### 可能的 Jellyfin 12 migration 覆盖缺口

Jellyfin 12 本身有 `FixIncorrectOwnerIdRelationships` migration，注释明确说明它用于清理由 auto-merge 错误产生的 video/movie `OwnerId` parent-child 关系。但它筛选的类型只有普通 `Video` 和 `Movie`，没有 `TV.Episode`。

这与当前现象高度吻合：这些受影响对象全部是 Episode，可能在升级时获得/保留了 local alternate / OwnerId 关系，却没有被该 migration 的 OwnerId cleanup 覆盖。

这个 migration omission 目前仍属于源码与实测共同支持的强推断，下一步先直接读取本机 Jellyfin v12 SQLite 数据库确认 Medalist 8 个 item 的 `OwnerId`、`PrimaryVersionId` 以及 `LinkedChildren.ChildType`，再决定修复方式。

只读诊断脚本：

```text
experiments/jellyfin12-nfo-refresh/10-medalist-local-alternate-db-diagnosis.py
```

它使用 SQLite `mode=ro` 打开数据库，只输出关系，不修改数据库。
