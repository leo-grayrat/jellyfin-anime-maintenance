# 2026-08-14 Episode metadata no-NFO pilot 实机记录

本记录只记真实 Windows/Jellyfin 12 结果，以及随后核对 Jellyfin 当前源码得到的解释。

## 1. 实验目的

v3 canonical View 已经解决季号/集号、LocalAlternateVersion、Series 误匹配、光美目录层级和语言后缀字幕问题。剩余集中问题是：

- 葬送のフリーレン Season 2：S/E 正确，但 Episode Name 仍是 canonical 文件名；只有部分集有英文 Overview；
- 【推しの子】 Season 3：同样 S/E 正确，但 Episode Name 仍是 canonical 文件名；只有部分集有英文 Overview。

为了判断 sparse correction NFO 是否压住远程 Episode metadata，建立 4 集、无 NFO 的独立 hardlink pilot：

```text
D:\Resource\BangumiLink\MetadataPilot-v3\2026年1月新番
```

样本：

- Frieren S02E02：v3 中 Overview 有，Name fallback；
- Frieren S02E06：v3 中 Overview 无，Name fallback；
- Oshi no Ko S03E02：v3 中 Overview 有，Name fallback；
- Oshi no Ko S03E07：v3 中 Overview 无，Name fallback。

Series 目录仍保留已验证的 `[tmdbid-...]`，视频仍使用 `SxxEyy - ...`，唯一主动移除的变量是 NFO。

## 2. 真实结果：去掉 NFO 无变化

用户在 Jellyfin 中新建独立 pilot TV 库，自然首次扫描后截图确认：结果与 v3 完全一致。

- Frieren S02E02：仍为文件名式 Name，英文 Overview 仍存在；
- Frieren S02E06：仍为文件名式 Name，Overview 仍为空；
- Oshi no Ko S03E02：仍为文件名式 Name，英文 Overview 仍存在；
- Oshi no Ko S03E07：仍为文件名式 Name，Overview 仍为空。

因此这一项仍然成立：

> sparse correction NFO 不是产生该残余 metadata 行为的必要条件。继续删 NFO 或制造新的 canonical View 不能解决这个问题。

## 3. Jellyfin 12 当前源码能解释的部分

### 3.1 当前 Name / Overview 组合更像 provider 返回不完整，而不是文件结构错误

`MetadataService.RefreshWithProviders` 使用新的临时 metadata item 收集 provider 结果。remote provider 返回的字段会先合并到临时结果；已有文件名式 Name 与空 Overview 的最终行为取决于 refresh mode、replaceAllMetadata 和 provider 是否实际返回字段。

### 3.2 OMDb 可以解释“英文简介有、标题没有”

Jellyfin 的 `OmdbEpisodeProvider` 在非 English metadata language 下不会设置 Episode Name，但仍可写入 Overview、IMDb ID、评分等信息。

因此当前典型状态：

```text
Name     = S02E02 - [KitaujiSub] ...
Overview = English plot
IMDb     = present
```

与 OMDb 成功、TMDB Episode metadata 没有提供/没有被采用的行为高度吻合。

对于 E06 / E07 连 Overview 都没有的情况，则说明对应 remote Episode metadata 仍需继续查实际 provider 执行结果。

## 4. 语言设置实验：此前“已排除”的结论需要撤回

曾怀疑 pilot 库记录的：

```text
PreferredMetadataLanguage = zh
MetadataCountryCode = CN
```

可能影响 TMDB Episode lookup。用户随后把媒体库设置明确改为：

```text
Chinese (Simplified)
People's Republic of China
```

界面上四个 Episode 仍然没有变化。

最初曾据此写成“语言差异已排除”。2026-08-14 22:29 的 Debug 日志证明这个结论过早：这次操作之后执行的是普通媒体库扫描，**实际没有重新运行 Episode remote metadata provider**。

因此正确结论是：

> 这次“改语言 + 普通扫描后界面没变化”不是有效的 Episode provider 语言 A/B 测试。`zh` / `zh-CN` 是否影响 TMDB Episode lookup，目前仍未由真实 provider refresh 排除。

## 5. 22:29 Debug 日志：只运行了 Series 级 TmdbMissingEpisodeProvider

真实 Debug 日志中，两个 Series 被扫描：

```text
Process new item '"【我推的孩子】"'
Process new item '"葬送的芙莉莲"'
```

随后明确出现：

```text
"TmdbMissingEpisodeProvider" reports change to ...【推しの子】 第3期...
"TmdbMissingEpisodeProvider" reports change to ...葬送のフリーレン 第2期...
Running "TmdbMissingEpisodeProvider" for ...
```

但整段日志没有：

```text
EpisodeMetadataService
TmdbEpisodeProvider
OmdbEpisodeProvider
```

这里必须区分两个不同 provider：

- `TmdbMissingEpisodeProvider` 是 **Series 级 custom provider**，用途是创建/同步 TMDB 中“缺失或未播出的虚拟 Episode”；
- `TmdbEpisodeProvider` 才是给一个真实 Episode 拉取 Name / Overview / ProviderIds 的 **Episode remote metadata provider**。

因此日志中的 `TmdbMissingEpisodeProvider reports change` **不能解释为“TMDB Episode metadata 已重新抓取”**。

源码还显示，`TmdbMissingEpisodeProvider.HasChanged()` 对“有 TMDB ID 的 Series”就会报告 change；所以 `reports change` 本身也不等价于 TMDB 返回了新 Episode metadata。

## 6. 为什么普通扫描没有重新跑 Episode provider

Jellyfin `MetadataService.GetProviders()` 的当前规则是：

- 首次 refresh、明确 `FullRefresh`、ReplaceAll、或 item 被判断为需要 refresh 时，运行全部 provider；
- 否则普通增量扫描只运行实现了 `IHasItemChangeMonitor` 且报告变化的 provider。

`TmdbEpisodeProvider` / `OmdbEpisodeProvider` 并不是这次普通增量扫描中被触发的 provider，所以“改语言后再普通扫描”不会重新获取这四个已存在 Episode 的 remote metadata。

这本身目前更像正常的增量刷新语义，不单独作为 Jellyfin bug。

## 7. 下一步真实验证

下一步不再改文件、不重建库，只在 pilot 中选 **一个 Overview 缺失的 Episode**（优先 Frieren S02E06），在 Debug 日志开启期间通过 Jellyfin UI：

```text
刷新元数据 -> 搜索缺少的元数据
```

Jellyfin Web 当前实现会把这个选项发送为：

```text
MetadataRefreshMode = FullRefresh
ReplaceAllMetadata  = false
```

这会强制运行 Episode remote providers，但不会采用 ReplaceAll 删除旧 metadata。

预期 Debug 日志应直接出现：

```text
Running TmdbEpisodeProvider for ...S02E06...
Running OmdbEpisodeProvider for ...S02E06...
```

并在 provider 无结果时出现：

```text
TmdbEpisodeProvider returned no metadata for ...
OmdbEpisodeProvider returned no metadata for ...
```

这才是下一步有判别力的真实 provider 诊断。

## 8. Fate/strange Fake 特别篇

FSF 的 `Whispers of Dawn` 与上述问题分开处理。它在外部数据库中是独立 TV Movie，而不是当前 TV Series 的普通 Episode。因此把它放在 Series 的 `S00E01` 下时，不应期待常规 Series Episode lookup 自动获得完整 metadata；后续更适合做明确的本地 metadata 特例。

## 9. 上游 issue 候选

本轮两个可能的 Jellyfin 上游问题继续单独存档：

```text
docs/history/2026-08-14-jellyfin-upstream-issue-candidates.md
```

其中第二项已同步修正：当前 Debug 日志证明普通扫描没有重跑 Episode provider，所以不能拿本次语言修改后的“无变化”作为 TMDB Episode lookup 失败的直接证据。

## 10. 当前边界

- 不修改 v3 构建器；
- 不再以删除 sparse NFO 作为修复方向；
- 语言假设恢复为“待有效 FullRefresh 验证”，而不是“已排除”；
- 不对生产库执行 ReplaceAll metadata；
- 下一步只在临时 pilot 的单个 Episode 上执行 `FullRefresh + replaceAllMetadata=false`；
- 真实结论仍以本地 Windows + Jellyfin 12 结果为准。
