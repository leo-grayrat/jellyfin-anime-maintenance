# 2026-08-14 Episode metadata 最终归因：TMDB 建模与本地季数不一致

本记录承接 `2026-08-14-episode-metadata-no-nfo-pilot.md`，记录该调查最终从“疑似 Jellyfin provider bug”转向“外部 metadata source 建模不一致”的结论。

## 1. 已有实机证据

no-NFO pilot 中，Frieren S02E06 执行单 Episode：

```text
刷新元数据 -> 搜索缺少的元数据
```

对应 `FullRefresh + replaceAllMetadata=false`。Debug 日志确认：

```text
EpisodeNfoProvider returned no metadata
Running TmdbEpisodeProvider
TmdbEpisodeProvider returned no metadata
Running OmdbEpisodeProvider
```

此前已经排除：

- sparse NFO 是必要原因；
- 普通扫描没有真正运行 Episode provider 的误判；
- DisplayOrder 被设成 Absolute/DVD 等特殊顺序（Series 当前为 Aired）。

## 2. TMDB 数据模型核对

继续核对 TMDB 后发现，本地为了符合动画观看习惯使用的季数，并不总能直接对应 TMDB 的 `season_number`。

### Frieren

v3 曾把：

```text
葬送のフリーレン 第2期 (2026)
```

pin 到原 Series TMDB：

```text
209867
```

同时文件仍保持：

```text
S02E01 ...
S02E06 ...
```

但 TMDB 原 Series `209867` 当前并没有这些实际 Season 2 Episode。用户进一步确认，第二期被 TMDB 作为另一个独立 TV 条目维护：

```text
327813
```

因此 Jellyfin 使用：

```text
series = 209867
season = 2
episode = 6
```

查询得到 `TmdbEpisodeProvider returned no metadata` 是符合 TMDB 当前数据结构的，不支持把它归为 Jellyfin bug。

### Oshi no Ko

本地按动画观看习惯使用 Season 1 / Season 2 / Season 3。

但 TMDB `203737` 对已存在内容并不是这样组织：第一、第二期内容被放在同一个 Season 1 下连续编号，而不是对应本地 S01 / S02。用户进一步确认，当前也不存在可以与本地第二、第三季直接一一对应的独立 TMDB Series 条目。

因此本地：

```text
S03E07
```

去请求：

```text
203737 / season 3 / episode 7
```

返回空同样不能归因为 Jellyfin provider bug。

## 3. 最终结论

此前的“TmdbEpisodeProvider 在正确 Series/S-E 下错误返回 no metadata”上游候选被排除。

真正的问题是：

> 本地动画收藏使用的“第 X 季”语义，与 TMDB 对部分日本动画采用的独立 Series、连续 Episode、非传统 Season 建模不一致。

因此：

- Jellyfin 的 Series/S/E 解析可以完全正确；
- Jellyfin 也可以正确调用 `TmdbEpisodeProvider`；
- 但只要本地 `SxxEyy` 与 TMDB 的 `series_id + season_number + episode_number` 不同构，就无法依赖 TMDB provider 自动补齐 Episode metadata。

## 4. 对当前 v3 的影响

v3 文件结构本身仍然成立，不应因为 metadata source 的建模差异再造 v4。

但以下两项 TMDB pin 不能再理解为“固定正确 TMDB Series 后，所有 Episode metadata 会按本地 S/E 自动恢复”：

- Frieren 第2期 -> `209867`：对 Episode lookup 明显不匹配；
- Oshi no Ko 第3期 -> `203737`：TMDB 的 season/episode model 与本地 S03 不匹配。

后续 metadata 修复应把“本地展示编号”和“外部 provider 编号”分开处理。

## 5. 主线后续方向

不再继续追候选 2 的 Jellyfin bug，也不继续修改 View 文件结构。

下一步应比较可用 metadata source（TMDB / TVDB / IMDb/OMDb 等）对这些动画的建模方式，选择能稳定映射到本地季数的一种；如果没有统一 source，则对少数 mismatch 作品生成明确的本地 Episode NFO，以保留本地希望展示的 Season 2 / Season 3，同时写入正确标题、简介和 provider IDs。

Fate/strange Fake `Whispers of Dawn` 也属于类似“本地希望作为特别篇显示、外部数据库却作为独立作品维护”的 source-model mismatch，应和上述问题一起按本地 metadata 特例思路处理。
