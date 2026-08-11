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
- `幼女战记（2017）`：错误组有 25 个 source，但 correction target 只有 12 个，另外 13 个 source 尚未纳入本轮规则映射。
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

先验证拆掉 stale relation 后，8 个物理 item 是否立即都能通过 normal query 和 `/Shows/{SeriesId}/Episodes` 独立可见。此 pilot 故意不自动 Series FullRefresh，以便一次只验证“清除 alternate relationship”这一变量。
