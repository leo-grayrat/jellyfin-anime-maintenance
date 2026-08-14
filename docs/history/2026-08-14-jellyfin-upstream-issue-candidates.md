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

## 候选 2：正确 Series / S-E 下，TmdbEpisodeProvider 仍可能返回 no metadata

### 初始现象

在全新的 no-NFO 独立测试库第一次自然扫描后：

- Series 已通过 `[tmdbid-...]` 正确固定身份；
- S/E 文件命名正确；
- Jellyfin 能创建正确 Season；
- Frieren S2 / Oshi no Ko S3 的 Episode Name 仍保持文件名；
- 一部分 Episode 只获得英文 Overview / IMDb ID / 评分；另一部分连 Overview 也没有。

删除 sparse NFO 后，第一次自然扫描行为仍与 v3 一样，所以 NFO 不是必要条件。

### 22:29 Debug 日志修正了一个误判

用户把 pilot 库语言改为 `Chinese (Simplified)` + `People's Republic of China` 后普通扫描，界面无变化。但 Debug 日志只出现 Series 级 `TmdbMissingEpisodeProvider`，没有运行 `TmdbEpisodeProvider` / `OmdbEpisodeProvider`。

因此“改语言后普通扫描无变化”不能当成 Episode provider 失败证据；普通增量扫描没有重跑 Episode remote provider 更像正常语义。

### 22:39 新证据：单 Episode FullRefresh 确认 TMDB no metadata

随后用户对 no-NFO pilot 的 Frieren S02E06 单独执行：

```text
刷新元数据 -> 搜索缺少的元数据
```

对应 `FullRefresh + replaceAllMetadata=false`。真实 Debug 日志明确出现：

```text
Running "EpisodeNfoProvider" for ...S02E06...
"EpisodeNfoProvider" returned no metadata for ...S02E06...
Running "TmdbEpisodeProvider" for ...S02E06...
"TmdbEpisodeProvider" returned no metadata for ...S02E06...
Running "OmdbEpisodeProvider" for ...S02E06...
```

界面刷新后仍没有变化。

这使候选 2 明显变强：

- NFO 干扰已经排除；
- 这次不是普通扫描，`TmdbEpisodeProvider` 确实被强制执行；
- Jellyfin 对这个实际物理 Episode 明确得到 `HasMetadata=false`；
- Series 目录 pin 为 TMDB `209867`，文件名明确是 `S02E06`；
- 外部公开资料独立确认 Frieren 第2期第6话真实存在，并已在 2026-02-27 播出。

### 为什么现在仍只叫“候选”

`TmdbEpisodeProvider.GetMetadata()` 最终调用：

```text
GetEpisodeAsync(seriesTmdbId, seasonNumber, episodeNumber,
                SeriesDisplayOrder, MetadataLanguage,
                imageLanguages, MetadataCountryCode)
```

当前 Debug 日志没有打印这些参数的最终值，也没有直接显示 TMDB endpoint 响应。因此仍有两类根因没有区分：

1. Jellyfin 构造/传递的 lookup input 有问题，例如 `SeriesDisplayOrder`、language/country 或其他参数造成错误查询；
2. lookup input 正确，但 TMDB 当前 endpoint 对该请求本身返回空/null。

只有在确认 TMDB 当前确实有对应 S02E06 数据、并且 Jellyfin lookup input 正确后，才能把它提升成明确的 Jellyfin 上游 bug。

### 当前下一步

只读完成两件事：

1. 核对 TMDB 当前 `209867 / season 2 / episode 6` 以及 `203737 / season 3 / episode 7` 的真实数据；
2. 导出 Jellyfin 对相同 Episode 的实际 lookup input，重点看 `SeriesDisplayOrder`、MetadataLanguage、MetadataCountryCode、season、episode。

如果 TMDB 有数据而 Jellyfin 仍返回 no metadata，候选 2 就可以转成可复现的上游 issue。

---

## 当前原则

- 两个候选都先存档，不立即上游提 issue；
- 后续主线排障产生的新证据继续补到本文件；
- 对已经被新证据推翻的中间结论要明确修正；
- 最终若确认，需要分别写复现步骤、预期行为、实际行为、版本、日志和源码定位，避免把不同根因混成一个 issue。
