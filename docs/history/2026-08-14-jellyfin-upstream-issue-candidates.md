# 2026-08-14 Jellyfin 上游 issue 候选记录

本文件记录本次 Jellyfin 12.0.0 排障过程中出现的、未来可能值得向 `jellyfin/jellyfin` 上游报告的问题，以及后来被证据排除的候选。当前只有候选 1 仍保留为真正的 Jellyfin 上游 issue 候选。

## 候选 1：ReplaceAll 在 provider metadata 不完整时可能造成既有字段丢失

### 现象

对 Medalist S02E01 做受控 `FullRefresh + replaceAllMetadata=true` 后，原先存在的 Overview 被清空，而 Name 仍保持旧值。

当前源码中的字段合并存在一个值得注意的不对称：

- 新 `Name` 为空时，有显式 safeguard，不会用空值覆盖旧 Name；
- 新 `Overview` 为空时，replace 模式允许覆盖旧 Overview。

因此，当一次 ReplaceAll 得到的是“不完整的 provider metadata”时，可能发生：

```text
旧 Name      -> 保留
旧 Overview  -> 被清空
```

### 为什么可能是上游 bug

如果 provider lookup 本身是正确的，只是该语言下某个字段为空，那么 ReplaceAll 是否应该把数据库中已有的合法字段直接删除，存在明显的数据保全争议。

尤其 Name 与 Overview 对“provider 没给这个字段”采取不同策略，值得上游审查。

### 仍需区分的三种归因

1. Jellyfin 传给 TMDB 的 lookup 输入错误：应报告 Episode provider lookup bug；
2. lookup 正确，TMDB 正常返回空 Overview，而 ReplaceAll 删除旧 Overview：更像 partial metadata 数据丢失 bug；
3. TMDB 实际返回了 Overview，但 Jellyfin mapper 丢失：属于 provider mapper bug。

在这三者未区分前，不提交上游 issue。

---

## 已排除候选 2：正确 Series / S-E 下，TmdbEpisodeProvider 返回 no metadata

### 初始现象

在全新的 no-NFO 独立测试库第一次自然扫描后：

- Series 通过 `[tmdbid-...]` 固定身份；
- S/E 文件命名正确；
- Jellyfin 能创建正确 Season；
- Frieren S2 / Oshi no Ko S3 的 Episode Name 仍保持文件名；
- 一部分 Episode 只获得英文 Overview / IMDb ID / 评分；另一部分连 Overview 也没有。

删除 sparse NFO 后行为不变。随后对 Frieren S02E06 单独执行 `FullRefresh + replaceAllMetadata=false`，真实 Debug 日志明确出现：

```text
Running "EpisodeNfoProvider" for ...S02E06...
"EpisodeNfoProvider" returned no metadata for ...S02E06...
Running "TmdbEpisodeProvider" for ...S02E06...
"TmdbEpisodeProvider" returned no metadata for ...S02E06...
Running "OmdbEpisodeProvider" for ...S02E06...
```

一度怀疑 Jellyfin 的 Episode lookup 输入有 bug。

### 最终归因：TMDB 的数据模型与本地季数模型不一致

继续核对 TMDB 后发现，问题并不是 Jellyfin 明明查询到存在的 S/E 却返回空，而是我们本地使用的“第 2 季 / 第 3 季”编号与 TMDB 对这些动画的组织方式不一致。

#### Frieren

本地 v3 把 `葬送のフリーレン 第2期` pin 到原 Series TMDB `209867`，同时视频仍标为 `S02E01...`。

但 TMDB 当前对原 Series `209867` 的第二季并没有这些实际 Episode；用户进一步确认，第二期在 TMDB 中作为另一个独立 TV 条目存在（`327813`）。因此 Jellyfin 对：

```text
series = 209867
season = 2
episode = 6
```

得到 `TmdbEpisodeProvider returned no metadata` 是符合外部数据库当前状态的。

#### Oshi no Ko

TMDB `203737` 并不按本地的 Season 1 / Season 2 / Season 3 方式组织。已存在内容被放在同一个 Season 1 下连续编号；用户确认 TMDB 当前也没有与本地“第 2 季 / 第 3 季”一一对应的独立 Series 条目。

因此本地 `S03E07` 去请求 TMDB `203737 / season 3 / episode 7` 时得到空，也不能归因为 Jellyfin bug。

### 结论

候选 2 **不再视为 Jellyfin 上游 issue**。真正问题是：

> 本地为了符合动画观看习惯而采用的“第 X 季”编号，与 TMDB 对某些日本动画采用的“独立 Series / 连续 Episode / 非传统 Season”建模不一致。

这属于 metadata source schema mismatch，而不是目前已有证据能够支持的 Jellyfin provider bug。

这也意味着 v3 中对 Frieren / Oshi no Ko 的 TMDB pin 不能继续简单理解为“固定正确 Series ID 后 TMDB 就能按本地 SxxEyy 自动补全 Episode metadata”。后续主线应该决定如何在保留本地季数展示的前提下补齐 metadata，而不是继续追 Jellyfin provider issue。

---

## 当前原则

- 候选 1 保留，暂不提交上游；
- 候选 2 已由外部数据库建模不一致解释，明确标记为排除；
- 后续如果发现新的上游候选，仍要求先把 Jellyfin 行为和外部 provider 数据本身区分开；
- 最终若提交 issue，需要分别写复现步骤、预期行为、实际行为、版本、日志和源码定位，避免把 provider 数据缺失误报成 Jellyfin bug。
