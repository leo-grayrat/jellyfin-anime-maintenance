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

用户在 Jellyfin 中新建独立 pilot TV 库，自然扫描后截图确认：结果与 v3 完全一致。

- Frieren S02E02：仍为文件名式 Name，英文 Overview 仍存在；
- Frieren S02E06：仍为文件名式 Name，Overview 仍为空；
- Oshi no Ko S03E02：仍为文件名式 Name，英文 Overview 仍存在；
- Oshi no Ko S03E07：仍为文件名式 Name，Overview 仍为空。

因此：

> sparse correction NFO 不是产生该残余 metadata 行为的必要条件。继续删 NFO 或制造新的 canonical View 不能解决这个问题。

## 3. Jellyfin 12 当前源码解释

### 3.1 当前 Name / Overview 组合更像 provider 返回不完整，而不是文件结构错误

`MetadataService.RefreshWithProviders` 使用新的临时 metadata item 收集 provider 结果。若 remote provider 没提供 Name，最终现有文件名式 Name 会继续存在；空 Overview 则可以被后续 provider 填入。

### 3.2 OMDb 恰好解释“英文简介有、标题没有”

Jellyfin 的 `OmdbProvider.FetchEpisodeData` 在非 English metadata language 下不会设置 Episode Name，因为 OMDb 没有本地化标题；但 `ParseAdditionalMetadata` 仍会设置 Overview，并写入 IMDb ID、评分等信息。

因此当前典型状态：

```text
Name     = S02E02 - [KitaujiSub] ...
Overview = English plot
IMDb     = present
```

与 OMDb 成功、TMDB Episode metadata 没有提供可采用结果的行为高度吻合。

对于 E06 / E07 连 Overview 都没有的情况，则说明 OMDb 对这些当前集数也没有返回可用 Episode 数据，或 lookup 未命中。

## 4. language 假设也已被真实实验排除

曾怀疑 v3 验证库记录的：

```text
PreferredMetadataLanguage = zh
MetadataCountryCode = CN
```

可能导致 Jellyfin 向 TMDB 传入不够明确的 `zh`。因此用户在独立 no-NFO pilot 库中把设置明确改为：

```text
Chinese (Simplified)
People's Republic of China
```

随后重新扫描，真实截图确认四个样本仍与此前完全一致：

- Frieren S02E02：文件名式 Name + 英文 Overview；
- Frieren S02E06：文件名式 Name + 无 Overview；
- Oshi no Ko S03E02：文件名式 Name + 英文 Overview；
- Oshi no Ko S03E07：文件名式 Name + 无 Overview。

因此：

> `zh` / `zh-CN` 语言设置差异不是当前残留问题的主因。不要继续通过改语言、删 NFO 或重做 View 试探。

## 5. 当前最强结论

到这里已经排除：

- canonical 路径/S-E 结构；
- sparse NFO；
- `zh` 与明确简体中文设置差异。

剩余问题已经收敛到 **remote Episode metadata lookup / provider 数据本身**：

- TMDB 对 Frieren S2 / Oshi no Ko S3 的这些具体 Episode 是否返回有效 Name / Overview；
- Jellyfin 构造的 EpisodeInfo（Series TMDB ID + season + episode + display order）是否和 TMDB 当前数据一致；
- OMDb 为什么仅部分集有数据。

下一步优先看真实 Jellyfin provider 日志 / 对应远程 endpoint，不再修改媒体文件布局。

## 6. Fate/strange Fake 特别篇

FSF 的 `Whispers of Dawn` 与上述问题分开处理。它在外部数据库中是独立 TV Movie，而不是当前 TV Series 的普通 Episode。因此把它放在 Series 的 `S00E01` 下时，不应期待常规 Series Episode lookup 自动获得完整 metadata；后续更适合做明确的本地 metadata 特例。

## 7. 当前边界

- 不修改 v3 构建器；
- 不再以删除 sparse NFO 作为修复方向；
- 不再继续试验中文语言代码；
- 不对生产库执行 ReplaceAll metadata；
- 下一步只读诊断 remote provider lookup / server logs；
- 真实结论仍以本地 Windows + Jellyfin 12 结果为准。
