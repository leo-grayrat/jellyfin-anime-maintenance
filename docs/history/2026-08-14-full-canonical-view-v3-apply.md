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

## 4. 当前下一步

停止继续修改构建器。下一步只做 Jellyfin 行为验证：新建独立 TV 验证库，只挂载：

```text
D:\Resource\BangumiLink\View-v3\2026年1月新番
```

重点检查：

- 186 个物理视频是否仍全部可追踪；
- normal Episode 是否仍为 181，5 个差值是否仍全部是真实多版本；
- 《名探偵プリキュア！》是否只剩正常 `Season 01`，且 NCOP 不再成为 S01E11；
- 四个 `[tmdbid-...]` Series 是否得到正确网络身份；
- 语言后缀字幕是否正常挂到对应 Episode。

生产 Jellyfin roots 仍不切换，直到 v3 验证完成。
