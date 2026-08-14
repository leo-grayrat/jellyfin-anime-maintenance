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

## 2. 真实结果

用户在 Jellyfin 中新建独立 pilot TV 库，自然扫描后截图确认：结果与 v3 完全一致。

- Frieren S02E02：仍为文件名式 Name，英文 Overview 仍存在；
- Frieren S02E06：仍为文件名式 Name，Overview 仍为空；
- Oshi no Ko S03E02：仍为文件名式 Name，英文 Overview 仍存在；
- Oshi no Ko S03E07：仍为文件名式 Name，Overview 仍为空。

因此：

> sparse correction NFO 不是产生该残余 metadata 行为的必要条件。继续删 NFO 或制造新的 canonical View 不能解决这个问题。

## 3. Jellyfin 12 当前源码解释

### 3.1 remote provider 合并不会覆盖已有非空字段

`MetadataService.RefreshWithProviders` 调用 remote provider 时，将 provider 结果合并进临时 metadata 的 `replaceData` 设为 false。

`MergeBaseItemData` 对 Name / Overview 的规则都是：只有 `replaceData=true` 或目标字段为空时才覆盖/填入。

这说明已经由文件名产生的非空 Name 很容易保留下来，而空 Overview 可以被后续 provider 填入。

### 3.2 OMDb 恰好解释“英文简介有、标题没有”

Jellyfin 的 `OmdbProvider.FetchEpisodeData` 在非 English metadata language 下不会设置 Episode Name，因为 OMDb 没有本地化标题；但 `ParseAdditionalMetadata` 仍会设置 Overview，并写入 IMDb ID、评分等信息。

因此当前典型状态：

```text
Name     = S02E02 - [KitaujiSub] ...
Overview = English plot
IMDb     = present
```

与 OMDb 成功、TMDB Episode metadata 没有提供可采用结果的行为完全吻合。

对于 E06 / E07 连 Overview 都没有的情况，则说明 OMDb 对这些当前集数也没有返回可用 Episode 数据，或 lookup 未命中。

### 3.3 当前最值得检查的是 TMDB language 参数

v3 验证库当前配置：

```text
PreferredMetadataLanguage = zh
MetadataCountryCode = CN
```

Jellyfin `TmdbUtils.NormalizeLanguage()` 对单独的 `zh` 不会结合 CountryCode 生成 `zh-CN`，而是原样返回 `zh`。TMDB Episode provider 又把这个值直接用于 Episode 请求。

因此下一项最低成本验证是：只修改临时 pilot 库，把 Preferred Metadata Language 改为明确的 `zh-CN` / Chinese (Simplified, China)，然后重新刷新这 4 集。

这仍然只是待验证假设，不能在本地结果出来前定性。

## 4. Fate/strange Fake 特别篇

FSF 的 `Whispers of Dawn` 与上述问题分开处理。它在外部数据库中是独立 TV Movie，而不是当前 TV Series 的普通 Episode。因此把它放在 Series 的 `S00E01` 下时，不应期待常规 Series Episode lookup 自动获得完整 metadata；后续更适合做明确的本地 metadata 特例。

## 5. 当前边界

- 不修改 v3 构建器；
- 不再以删除 sparse NFO 作为修复方向；
- 不对生产库执行 ReplaceAll metadata；
- 下一步只在临时 metadata pilot 库验证 `zh` 与 `zh-CN` 的差异；
- 若 `zh-CN` 仍完全无变化，再直接诊断对应 TMDB Episode endpoint / Jellyfin lookup 输入，而不是继续改文件布局。
