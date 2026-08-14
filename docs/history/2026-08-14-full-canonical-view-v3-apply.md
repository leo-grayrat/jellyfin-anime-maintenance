# 2026-08-14 Full Canonical View v3 Apply 与 manifest 实机记录

本记录只记真实 Windows/NTFS 运行结果，以及随后对实际 `full-manifest-v3.csv` 的核验。

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
- operation 与文件类型一致：视频/字幕为 HARDLINK，其他文件为 COPY。

### 2.1 78 个语言后缀字幕

321 个 correction sidecar 由：

- 243 个 NFO；
- 78 个 `.ass` 语言后缀字幕；

组成。78 个字幕逐一都能唯一匹配到对应 correction video，且 `ExpectedKey` 一致。

实际来源分布：

- 2026年1月新番 / 名探偵プリキュア！：54；
- 2025年7月新番 / Clevatess：24。

### 2.2 名探偵プリキュア！

v3 manifest 中该作品共 113 行。媒体路径不再保留 27 个 `[FLsnow]...[01]`～`[27]` 单集目录作为 season-like 层级：

- 正片/NFO/字幕落入 `名探偵プリキュア！ (2026)\Season 01\...`；
- 3 个字体文件仍位于 `Season 01\[FLsnow][Star-Detective_Precure][Fonts]\`，属于非媒体资源；
- `NCOP_ED_01` 唯一落入 `名探偵プリキュア！ (2026)\extras\...`，Role 为 `PASSTHROUGH_VIDEO`，`ExpectedKey` 为空，不再伪装成 S01E11。

### 2.3 四个 Series provider pin

实际 manifest 只出现以下四个 `[tmdbid-...]` series folder，未扩散到其他 Series：

- `Fate strange Fake (2026) [tmdbid-229858]`：28 行；
- `メダリスト 第2期 (2026) [tmdbid-237529]`：26 行；
- `【推しの子】 第3期 (2026) [tmdbid-203737]`：22 行；
- `葬送のフリーレン 第2期 (2026) [tmdbid-209867]`：20 行。

## 3. 当前下一步

文件层还差一次真实 Windows 二次 dry-run 来证明 v3 全部可复用。目标：

```text
Reusable rows: 1227
Rows to create: 0
Conflicts: 0
```

通过后，再把 `D:\Resource\BangumiLink\View-v3\2026年1月新番` 接入一个新的独立 Jellyfin 验证库，复查光美 season、NCOP、四个 Series 身份与真实多版本行为。
