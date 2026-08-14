# 2026-08-14 Full Canonical View v3 Apply 与 manifest 实机记录

本记录只记真实 Windows/NTFS/Jellyfin 12 运行结果，以及随后对实际 `full-manifest-v3.csv` 和 v3 验证库的核验。

## 1. v3 真实 Apply

真实 Windows 输出：

```text
=== Python Full Canonical View v3 Preflight ===
Mode: READ ONLY
View root:          D:\Resource\BangumiLink\View-v3
Production roots:   9
Source files:       1227
Source videos:      634
Correction targets: 243
CORRECTION_SIDECAR: 321
CORRECTION_VIDEO: 243
PASSTHROUGH_FILE: 272
PASSTHROUGH_VIDEO: 391
HARDLINK rows:      738
COPY rows:          489
Reusable rows:      0
Rows to create:     1227
Conflicts:          0
```

Apply 前立即重跑 preflight，结果一致。随后 1227 / 1227 全部创建成功：

```text
=== Full View v3 Apply complete ===
Build id:     20260814-211137-174767
Created rows: 1227
Reused rows:  0
Manifest:     D:\Resource\BangumiLink\Logs\full-manifest-v3.csv
Build log:    D:\Resource\BangumiLink\Logs\full-build-20260814-211137-174767.csv
Validated v2 View and original media paths were not modified.
```

## 2. 实际 full-manifest-v3.csv 核验

对用户上传的真实 manifest 逐行检查，结果：

- 总行数：1227；
- `CORRECTION_VIDEO`：243；
- `CORRECTION_SIDECAR`：321；
- `PASSTHROUGH_VIDEO`：391；
- `PASSTHROUGH_FILE`：272；
- `HARDLINK`：738；
- `COPY`：489；
- `Status=CREATED`：1227；
- `BuildId=20260814-211137-174767`：1227；
- `SourcePath` 重复：0；
- `CanonicalPath` 重复：0；
- correction 行的 `ExpectedKey` 全部为合法 `SxxEyy`；
- correction canonical 文件名全部以对应 `SxxEyy - ` 开头；
- passthrough 行没有错误携带 `ExpectedKey`。

### 2.1 78 个语言后缀字幕

321 个 correction sidecar 由：

- 243 个 NFO；
- 78 个 `.ass` 语言后缀字幕；

组成。

实际来源分布：

- 2026年1月新番 / 名探偵プリキュア！：54；
- 2025年7月新番 / Clevatess：24。

### 2.2 名探偵プリキュア！

v3 manifest 中该作品共 113 行，canonical 路径的第一层只剩：

- `Season 01`：112 行；
- `extras`：1 行。

原先 27 个 `[FLsnow]...[01]`～`[27]` 单集目录不再作为 Season-like 媒体层级保留。`NCOP_ED_01` 唯一进入 `extras`，Role 为 `PASSTHROUGH_VIDEO`，`ExpectedKey` 为空。

### 2.3 四个 Series provider pin

实际 manifest 只出现以下四个 `[tmdbid-...]` series folder：

- `Fate strange Fake (2026) [tmdbid-229858]`；
- `メダリスト 第2期 (2026) [tmdbid-237529]`；
- `【推しの子】 第3期 (2026) [tmdbid-203737]`；
- `葬送のフリーレン 第2期 (2026) [tmdbid-209867]`。

## 3. Apply 后二次真实 preflight

Apply 完成后再次在真实 Windows 上运行不带 `--apply` 的 v3 preflight，得到：

```text
=== Python Full Canonical View v3 Preflight ===
Mode: READ ONLY
View root:          D:\Resource\BangumiLink\View-v3
Production roots:   9
Source files:       1227
Source videos:      634
Correction targets: 243
CORRECTION_SIDECAR: 321
CORRECTION_VIDEO: 243
PASSTHROUGH_FILE: 272
PASSTHROUGH_VIDEO: 391
HARDLINK rows:      738
COPY rows:          489
Reusable rows:      1227
Rows to create:     0
Conflicts:          0

DRY RUN finished. No files were written.
```

这证明 v3 文件层已经在真实 Windows/NTFS 上闭环：1227 个计划目标全部可复用，没有 stale/unmanaged/collision/conflict。

## 4. Jellyfin v3 独立验证

建立独立 TV 验证库：

```text
验证-v3-2026年1月
D:\Resource\BangumiLink\View-v3\2026年1月新番
```

第一次自然扫描后导出的真实 `jellyfin-v3-validation.json` 闭合为：

```text
Filesystem videos in v3 validation root: 186
Expanded Episode paths:                 185
Normal Episodes:                        180
```

这里不再应期待 181 个 normal Episode。正确解释是：

- 175 个 normal Episode 各有 1 个 media source；
- 5 个 normal Episode 各有 2 个真实版本，因此 180 个 normal Episode 对应 185 个 Episode media paths；
- 第 186 个物理视频是《名探偵プリキュア！》的 `NCOP_ED_01`，v3 已把它放入 `extras`，因此不再属于 Episode。

这说明 v3 的结构层比 v2 更完整地闭合：光美原先 27 个额外 Season-like 容器消失，NCOP 也不再冒充 Episode。

### 4.1 四个 Series 身份已修正

v3 验证库中的 Series provider identity：

- Medalist：TMDB 237529 / IMDb tt33310730 / TVDB 433953；
- Fate/strange Fake：TMDB 229858 / IMDb tt32864316 / TVDB 436779；
- 【推しの子】：TMDB 203737 / IMDb tt21030032 / TVDB 421069；
- 葬送のフリーレン：TMDB 209867 / IMDb tt22248376 / TVDB 424536。

因此 v2 的“Series 本身匹配错作品”问题已经解决。

### 4.2 剩余问题已进入 Episode metadata 层

当前集中残留不是 S/E 结构错误：

- 葬送のフリーレン Season 2：Season ProviderIds / Overview 为空；S02E01-S02E10 的 Name 仍为 canonical 文件名。Episode 都获得 IMDb ID，但只有 E02-E05 有 Overview；
- 【推しの子】 Season 3：Season ProviderIds / Overview 为空；S03E01-S03E11 的 Name 仍为 canonical 文件名。Episode 都获得 IMDb ID，但只有 E02-E06 有 Overview；
- Fate/strange Fake Season 1：Season provider identity 正常，S01E01-S01E13 的标题与 Overview 正常；Season 0 ProviderIds 为空，S00E01 没有 provider id / Overview，Name 为 `S00E01 -`。

这些 correction Episode 的 same-name NFO 仍只含 Season/Episode，Title/Plot/UniqueIds 为空。由于 Medalist 在同样存在 sparse NFO 的情况下可以正常取得 Episode metadata，不能把 sparse NFO 单独定性为唯一根因。

Fate/strange Fake 的 `Whispers of Dawn` 在 IMDb 中本身是独立的 2023 TV Movie，而不是当前 TV Series 的普通 Episode，因此把它作为该 Series 的 S00E01 展示时，不应期待常规 series-episode provider lookup 自动找到完整 metadata。

## 5. 当前结论

- v3 canonical 文件布局：完成；
- v3 Jellyfin 结构验证：通过；
- 后续不要再为标题/简介残缺继续制造 v4 路径布局；
- Episode Name / Overview / provider lookup 的后续工作归入 Issue #5；
- 生产 roots 仍未切换，等 metadata 策略确定后再决定切换时机。
