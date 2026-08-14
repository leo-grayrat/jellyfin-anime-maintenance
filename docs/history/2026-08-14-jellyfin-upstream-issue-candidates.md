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

## 候选 2：自动扫描中新季 Episode 的 TMDB metadata lookup 可能静默缺失

### 现象

在全新的 no-NFO 独立测试库中：

- Series 已通过 `[tmdbid-...]` 正确固定身份；
- S/E 文件命名正确；
- Jellyfin 能创建正确 Season；
- 但 Frieren S2 / Oshi no Ko S3 的 Episode Name 仍保持文件名；
- 一部分 Episode 只获得英文 Overview / IMDb ID / 评分；另一部分连 Overview 也没有。

删除 sparse NFO 后行为完全不变；把媒体库语言明确设为 `Chinese (Simplified)` + `People's Republic of China` 后也完全不变。

真实 INFO 日志只看到：

```text
Creating Season "第 3 季" entry for "【我推的孩子】"
Creating Season "第 2 季" entry for "葬送的芙莉莲"
```

未出现 TMDB/OMDb error，但 INFO 日志本身不足以证明 provider 是否执行，因为 Jellyfin 的 provider 运行日志主要在 Debug 级别。

### 当前源码能解释的部分

Jellyfin 的 OMDb Episode provider 在非英文 metadata language 下：

- 可以提供 IMDb ID、评分、Overview；
- 不写英文 Episode Name。

这与“文件名标题 + 英文简介 + IMDb/评分”的当前状态高度一致。

因此当前最强怀疑是：

> 对这些 Episode，TMDB Episode provider 没有给出可采用结果；OMDb 只对部分 Episode 提供了 fallback metadata。

### 为什么可能是上游 bug

如果后续证明 TMDB 对同一 `series_id + season + episode` 实际存在正常数据，而 Jellyfin 自动扫描仍没有采用，则问题可能位于：

- Episode lookup info 中 SeriesProviderIds / DisplayOrder / season 信息的传递；
- TMDB Episode provider 的调用条件；
- provider 返回 null / failure 时的静默处理；
- 新 Season 创建与 Episode metadata refresh 的时序。

### 仍需完成的归因

下一步应直接对照：

1. TMDB 官方 endpoint 对这些 Series/S/E 的真实返回；
2. Jellyfin 同一次自动扫描实际构造的 Episode lookup input；
3. Debug 日志中的 TheMovieDb / OMDb provider 执行结果。

如果 TMDB 本身就没有 Episode 数据，则这不是 Jellyfin bug，只是外部数据库数据缺失；如果 TMDB 有数据而 Jellyfin没拿到/没采用，才适合形成第二个上游 issue。

---

## 当前原则

- 两个候选都先存档，不立即上游提 issue；
- 后续主线排障产生的新证据继续补到本文件；
- 最终若确认，需要分别写复现步骤、预期行为、实际行为、版本、日志和源码定位，避免把不同根因混成一个 issue。
