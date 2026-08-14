# 2026-08-14 Jellyfin 上游 issue 候选记录

本文件只记录在本次 Jellyfin 12.0.0 排障过程中出现的、未来可能值得向 `jellyfin/jellyfin` 上游报告的问题。当前均先标记为 **候选**，不在尚未完成归因前直接提交上游 issue。

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

## 候选 2：首次自动识别中新季 Episode 的 TMDB metadata 可能未被正确采用

### 现象

在全新的 no-NFO 独立测试库第一次自然扫描后：

- Series 已通过 `[tmdbid-...]` 正确固定身份；
- S/E 文件命名正确；
- Jellyfin 能创建正确 Season；
- Frieren S2 / Oshi no Ko S3 的 Episode Name 仍保持文件名；
- 一部分 Episode 只获得英文 Overview / IMDb ID / 评分；另一部分连 Overview 也没有。

删除 sparse NFO 后，第一次自然扫描的行为仍与 v3 一样，所以 NFO 不是必要条件。

### 22:29 Debug 日志带来的重要修正

用户后来把 pilot 库语言改为：

```text
Chinese (Simplified)
People's Republic of China
```

然后普通扫描，界面没有变化。最初曾把它解释为“语言因素已经排除”。Debug 日志证明这个解释无效：普通扫描期间只出现 Series 级：

```text
TmdbMissingEpisodeProvider
```

没有出现：

```text
TmdbEpisodeProvider
OmdbEpisodeProvider
EpisodeMetadataService
```

`TmdbMissingEpisodeProvider` 是 Series 级 custom provider，用于创建/同步缺失或未播出的虚拟 Episode，并不是负责真实 Episode Name / Overview 的 `TmdbEpisodeProvider`。

因此：

> “改语言后普通扫描无变化”不能证明 TMDB Episode lookup 在新语言下仍失败，因为这次根本没有重新运行 Episode remote provider。

Jellyfin 当前 `MetadataService` 的增量扫描规则也能解释这一点：不是首次 refresh、不是 FullRefresh、也没有 item/provider change monitor 触发时，普通扫描不会重新运行全部 remote provider。这一点目前更像预期语义，本身不是 bug。

### 当前源码能解释的部分

Jellyfin 的 OMDb Episode provider 在非英文 metadata language 下：

- 可以提供 IMDb ID、评分、Overview；
- 不写英文 Episode Name。

这与“文件名标题 + 英文简介 + IMDb/评分”的当前状态高度一致。

此外，Jellyfin `Episode.GetLookupInfo()` 会直接从父 Series 复制：

```text
SeriesProviderIds = series.ProviderIds
SeriesDisplayOrder = series.DisplayOrder
```

因此，“Season 自身没有 ProviderIds 导致 Episode 完全拿不到 Series TMDB ID”这一简单解释已经可以排除。

### 为什么仍然可能是上游 bug

候选 2 现在只针对 **首次自然扫描时已经出现的 partial Episode metadata**，不再把后续普通扫描无变化算作证据。

如果后续用单 Episode `FullRefresh + replaceAllMetadata=false` 证明：

- TMDB 对同一 Series/S/E 有正常数据；
- Jellyfin 的 `TmdbEpisodeProvider` 也被真实调用；
- 但首次扫描仍没有正确采用这些 metadata；

那么问题可能位于：

- 首次 Episode refresh 时的 lookup input；
- 新 Season / Episode 建立与 remote provider refresh 的时序；
- TMDB provider 返回结果到最终 Episode 的合并路径。

如果显式 FullRefresh 本身也得到 `returned no metadata`，则应继续查 TMDB 数据和 lookup 参数，不能先认定 Jellyfin bug。

### 下一步归因

下一步只在临时 pilot 的一个 Overview 缺失 Episode 上执行：

```text
刷新元数据 -> 搜索缺少的元数据
```

Jellyfin Web 当前对应：

```text
MetadataRefreshMode = FullRefresh
ReplaceAllMetadata  = false
```

同时保持 Debug 日志。目标是直接看到：

```text
Running TmdbEpisodeProvider ...
Running OmdbEpisodeProvider ...
```

以及它们是否 `returned no metadata` 或报错。

---

## 当前原则

- 两个候选都先存档，不立即上游提 issue；
- 后续主线排障产生的新证据继续补到本文件；
- 对已经被新证据推翻的中间结论要明确修正，不把“普通扫描没刷新 Episode metadata”误当 provider lookup 失败；
- 最终若确认，需要分别写复现步骤、预期行为、实际行为、版本、日志和源码定位，避免把不同根因混成一个 issue。
