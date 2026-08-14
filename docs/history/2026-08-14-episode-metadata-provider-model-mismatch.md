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

## 3. TVDB / IMDb 对照核验

继续核对外部数据库后，TVDB 和 IMDb 明显更贴合本地希望展示的季数模型。

### Frieren

TheTVDB 把《葬送のフリーレン》作为同一个 Series 管理，并明确存在：

```text
Season 1: 28 episodes
Season 2: 10 episodes
```

其中第二季直接按：

```text
S02E01 ... S02E10
```

编号；S02E02、S02E06 等都存在正确标题、简介和播出日期。

IMDb 也把 2026 内容放在原 `Frieren: Beyond Journey's End` Series 下的 Season 2，存在 S2.E1 到 S2.E10，并有独立 Episode title / plot / rating。

因此 Frieren 的本地：

```text
S02E06
```

与 TVDB / IMDb 都天然同构，只与 TMDB 不同构。

### Oshi no Ko

TheTVDB 明确把《【推しの子】》2026 年内容作为 Season 3：

```text
S03E01 ... S03E11
```

且每集都已有标题、日期和简介；例如 S03E02、S03E03、S03E07 均能直接对应本地编号。

IMDb 也明确存在 `Oshi No Ko` Season 3 Episode 2、Episode 3、Episode 11 等独立 Episode 条目，说明其季数模型同样与本地 S03 对齐。

因此 Oshi no Ko 的本地 S03 同样更适合从 TVDB / IMDb 获取 metadata，而不是 TMDB。

### Fate/strange Fake -Whispers of Dawn-

TheTVDB 同时保留两种关系：

- 它是一个独立 Movie / OVA / TV Movie 条目；
- 同时又被链接为 `Fate/strange Fake` Series 的特殊集：`S00E01`，并标记为在 Season 1 Episode 1 之前播出的关键剧情特别篇。

这与当前 Jellyfin 中希望把它显示成：

```text
特别篇 / S00E01
```

完全同构。

IMDb 则主要把它作为独立 TV Movie `tt22264336` 管理，不适合作为 Series S00E01 的自动 Episode lookup source。

因此 FSF 特别篇也是 TVDB 明显优于 TMDB / IMDb 的一个案例。

## 4. 最终结论

此前的“TmdbEpisodeProvider 在正确 Series/S-E 下错误返回 no metadata”上游候选被排除。

真正的问题是：

> 本地动画收藏使用的“第 X 季”语义，与 TMDB 对部分日本动画采用的独立 Series、连续 Episode、非传统 Season 建模不一致。

因此：

- Jellyfin 的 Series/S/E 解析可以完全正确；
- Jellyfin 也可以正确调用 `TmdbEpisodeProvider`；
- 但只要本地 `SxxEyy` 与 TMDB 的 `series_id + season_number + episode_number` 不同构，就无法依赖 TMDB provider 自动补齐 Episode metadata。

与此同时，当前三个代表性异常对象在 TVDB 中都与本地模型天然同构：

- Frieren 第2季 -> TVDB Season 2；
- Oshi no Ko 第3季 -> TVDB Season 3；
- Fate/strange Fake -Whispers of Dawn- -> TVDB Series Special S00E01。

IMDb 对 Frieren / Oshi no Ko 的季数也基本同构，但 FSF 特别篇主要按独立 TV Movie 管理。因此从“一个 source 尽量覆盖三种异常”角度看，TVDB 是目前最合适的候选。

## 5. 对当前 v3 的影响

v3 文件结构本身仍然成立，不应因为 metadata source 的建模差异再造 v4。

但以下两项 TMDB pin 不能再理解为“固定正确 TMDB Series 后，所有 Episode metadata 会按本地 S/E 自动恢复”：

- Frieren 第2期 -> `209867`：对 Episode lookup 明显不匹配；
- Oshi no Ko 第3期 -> `203737`：TMDB 的 season/episode model 与本地 S03 不匹配。

后续 metadata 修复应把“本地展示编号”和“外部 provider 编号”分开处理。

## 6. 主线后续方向

优先验证 TVDB 是否能直接成为这些 mismatch 作品的 Episode metadata source，而不是继续维护 TMDB S/E 映射。

理想状态：

```text
本地 S02E06 / S03E07 / S00E01
        ↓
TVDB 使用相同 S/E 模型
        ↓
Jellyfin 直接获取对应标题 / 简介 / Provider IDs
```

只有在 Jellyfin 当前 provider 链无法方便地以 TVDB 为主，或者部分作品缺少 TVDB 数据时，才退回“显式本地 Episode NFO + 小型外部编号映射表”。

因此下一步不造新的 canonical View，也不改现有季集编号；只验证 Jellyfin 12 当前是否具备可用的 TVDB Episode metadata 获取路径，以及现有库/provider 配置如何选择或优先使用它。
