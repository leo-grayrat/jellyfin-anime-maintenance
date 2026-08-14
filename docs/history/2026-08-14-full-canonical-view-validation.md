# 2026-08-14 Full Canonical View 实机验证记录

本文只记录 2026-08-14 在真实 Windows + NTFS + Jellyfin 12.0.0 环境中已经发生并确认的结果，不把云端静态测试当作实机结论。

## 1. 生产范围重新闭合：678 / 676 / 634

最初统一 TV audit 使用的口径是“所有 `tvshows` 库，排除媒体库名为 `test` 的库”，因此得到 676。后续 Phase 2 一度把 634 误称为“生产 TV 总量”，原因是把 `C:\bangumi` 先验地当成测试目录。

真实 root 诊断输出最终确认：

```text
=== Jellyfin tvshows Root Scope Diagnostic ===
Mode: READ ONLY
- [INCLUDED] [2017年动画] D:\Bangumi\2017 :: 25 videos
- [INCLUDED] [2023年动画] D:\Bangumi\2023 :: 13 videos
- [INCLUDED] [2025年10月新番] D:\Bangumi\2025\2025-10 :: 42 videos
- [INCLUDED] [2025年1月新番] D:\Bangumi\2025\2025-01 :: 16 videos
- [INCLUDED] [2025年4月新番] D:\Bangumi\2025\2025-04 :: 12 videos
- [INCLUDED] [2025年7月新番] D:\Bangumi\2025\2025-07 :: 56 videos
- [INCLUDED] [2026年1月新番] D:\Bangumi\2026\2026-01 :: 186 videos
- [INCLUDED] [2026年4月新番] D:\bangumi\2026\2026-04 :: 204 videos
- [INCLUDED] [2026年7月新番] D:\Bangumi\2026\2026-07 :: 80 videos
- [EXCLUDED] [test] D:\Jellyfin-Repro :: 2 videos :: reason=D:\Jellyfin-Repro
- [EXCLUDED] [杂项TV动画] C:\bangumi :: 42 videos :: reason=C:\bangumi

Totals:
tvshows root entries: 11
INCLUDED videos:      634
EXCLUDED videos:      44
ALL tvshows videos:   678
Duplicate root paths: 0
Ambiguous roots:      0
```

正确解释是：

- D 盘 canonical View scope：634；
- `C:\bangumi` 的“杂项TV动画”：42，属于正式 TV，但保持原地；
- `D:\Jellyfin-Repro`：2，测试库；
- 正式 TV 总量：634 + 42 = 676；
- 全部 `tvshows`：676 + 2 = 678。

因此 676 从未是算术错误，错误在于后续把 634 与“全部生产 TV”混为一谈。

## 2. Python Full View v2：真实构建成功

Phase 2 从 PowerShell 迁移到 Python 后，真实只读 inventory 得到：

```text
Filesystem videos: 634
Jellyfin expanded Episode paths in selected roots: 634
JELLYFIN_ONLY: 0
FILESYSTEM_ONLY: 0
CORRECTION_SIDECAR: 243
CORRECTION_VIDEO: 243
PASSTHROUGH_FILE: 350
PASSTHROUGH_VIDEO: 391
```

真实 Apply 前 preflight：

```text
=== Python Full Canonical View Preflight ===
Mode: READ ONLY
Production roots:   9
Source files:       1227
Source videos:      634
Correction targets: 243
CORRECTION_SIDECAR: 243
CORRECTION_VIDEO: 243
PASSTHROUGH_FILE: 350
PASSTHROUGH_VIDEO: 391
HARDLINK rows:      738
COPY rows:          489
Reusable rows:      486
Rows to create:     741
Conflicts:          0
```

真实 Apply：

```text
=== Full View Apply complete ===
Build id:     20260814-194819-395761
Created rows: 741
Reused rows:  486
Manifest:     D:\Resource\BangumiLink\Logs\full-manifest-v2.csv
Build log:    D:\Resource\BangumiLink\Logs\full-build-20260814-194819-395761.csv
Original media paths were not renamed, moved, overwritten, or deleted.
```

随后第二次真实 dry-run：

```text
Reusable rows:      1227
Rows to create:     0
Conflicts:          0
```

这说明 v2 文件层构建在真实 Windows/NTFS 上闭环：1227 个计划目标全部存在并可复用。

## 3. Jellyfin 验证库：核心结构问题基本解决

创建独立媒体库 `验证-2026年1月`，只挂载：

```text
D:\Resource\BangumiLink\View\2026年1月新番
```

第一次自然扫描后，真实 audit export 成功：

```text
TV libraries:        12
Normal items:        874
Normal Episodes:     668
Expanded Episodes:   864
Filesystem videos:   864
Same-name NFOs:      361
NFO summaries:       361
NFO read errors:     0
```

验证库自身有 186 个物理视频；全局 expanded 从原先 678 增加到 864，差值正好 186。进一步检查得到：

- 原 `2026年1月新番`：186 个物理视频只有 120 个 normal Episode；
- v2 验证库：186 个物理视频对应 181 个 normal Episode；
- 186 个物理路径全部可在 expanded/MediaSources 中追踪，没有物理视频丢失；
- `186 - 181 = 5` 全部是实际存在的多版本，而不是错误 hidden alternate：死亡游戏 E08 的 v1/v2，以及 Medalist E02～E05 的双版本。

因此 canonical View 已基本解决原来由路径解析引起的错误 `LocalAlternateVersion` / hidden Episode 问题。

## 4. v2 验证暴露出的集中残留问题

### 4.1 四个 Series 网络身份不稳定

14 部作品中，大部分新库 Series Provider ID 与原库一致；集中出问题的是：

- `Fate strange Fake (2026)`；
- `メダリスト 第2期 (2026)`；
- `【推しの子】 第3期 (2026)`；
- `葬送のフリーレン 第2期 (2026)`。

其中 Medalist S2 与芙莉莲 S2 一度被误匹配到同一个无关 IMDb 项 `tt41541604`，界面出现 “Inspired by the haunting real life Addams Family tragedy” 等完全错误的简介。

v3 因此只对这四个已确认问题 Series 在 canonical 目录名中追加明确的 TMDB ID，不推广到全库。

### 4.2 《名探偵プリキュア！》一集一个子目录

原收藏把每集放在独立 `[FLsnow]...[01][1080p]` 等子目录中。v2 只给文件名加了 `S01Eyy`，保留了这些目录，因此 Jellyfin 同时生成：

- 一个正确的完整 `第 1 季`；
- 27 个额外的单集 Season-like 容器。

API 中实际存在 28 个 Season 对象。

此外 `NCOP_ED_01` 被识别成另一个 S01E11。

v3 将这部作品的 correction 正片压平到 `Season 01`，NCOP/ED 放入 `extras`。

### 4.3 语言后缀字幕未跟随 correction video

v2 的 sidecar 只识别完全同 stem：

```text
video.mkv
video.nfo
video.ass
```

但没有识别：

```text
video.chs.ass
video.cht.ass
video.sc.ass
video.tc.ass
```

实际有 78 个这类 correction sidecar：光美 54 个，Clevatess 24 个。v3 扩展了 sidecar 匹配规则。

## 5. PowerShell exporter 的一次假失败

第一次重新导出验证 JSON 时出现 361/361 NFO `ReadAllText` “路径中具有非法字符”。换一个全新的 PowerShell 进程后，同一脚本成功读取 361/361 NFO。

这与 PowerShell `Add-Type` 同进程缓存旧类型的行为吻合：当前 helper 如果发现 `TvaNativeFileSystem` 类型已存在，会直接复用，而不是重新编译本次 git pull 后的实现。

因此这次不是 NFO 文件坏掉，也不是 Jellyfin API 故障。

## 6. v3：独立 View-v3，不覆盖已验证 v2

新增入口：

```text
scripts/apply_jellyfin_full_canonical_view_v3.py
```

v3 固定写入：

```text
D:\Resource\BangumiLink\View-v3
```

使用独立 manifest：

```text
D:\Resource\BangumiLink\Logs\full-manifest-v3.csv
```

v3 不继承 Phase 1/v2 manifest，也不修改已验证的 `View`。

第一次真实 Windows preflight 暴露了一个只在 Windows 路径转换中出现的 bug：为了表示“不继承 Phase 1 manifest”，脚本传了空路径 `""`，最终被 `normalize_windows_path("")` 拒绝并报：

```text
ERROR: path must not be empty
```

修复方式不是放宽空路径，而是传一个明确不存在但合法的占位 manifest 路径。

修复后，真实 Windows v3 preflight 成功：

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

DRY RUN finished. No files were written.
```

关键变化完全闭合：

- correction sidecar：243 → 321，正好多 78 个语言后缀字幕；
- passthrough file：350 → 272，正好少 78；
- 总映射仍为 1227；
- 634 个视频、243 个 correction targets 均未变化；
- 0 collision / conflict。

## 7. 当前状态

截至本记录：

- v2 Full View：已真实 Apply，并通过 1227/1227 reusable 二次 preflight；
- v2 Jellyfin 独立验证：核心 hidden/alternate 结构问题基本解决；
- v3：已通过真实 Windows read-only preflight，尚未执行 `--apply`；
- 生产 Jellyfin roots 尚未切换；
- `C:\bangumi` 42 个正式杂项 TV 仍保持原地；
- 原始动画文件未移动、重命名或删除；
- 后续验证继续以本地 Windows + Jellyfin 输出为准，不以云端 fixture 代替实机结论。
