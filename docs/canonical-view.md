# Jellyfin 规范视图

本仓库当前方案不是重命名原收藏，而是在 `D:\Resource\BangumiLink` 下为 Jellyfin 构建规范 View。调查已经确认：仅写 NFO 可以修正 Episode 自身的季号/集号，但 Jellyfin 可能在读取 NFO 之前就根据完整路径建立错误的 `LocalAlternateVersion`。因此需要同时规范 Jellyfin 看到的路径。

详细实机记录见：

```text
docs/history/2026-08-14-full-canonical-view-validation.md
docs/history/2026-08-14-full-canonical-view-v3-apply.md
```

## 当前范围

真实 root 诊断已经闭合：

- 9 个 `D:\Bangumi` 正式 TV roots：634 个视频，进入 canonical View；
- `C:\bangumi` / `杂项TV动画`：42 个视频，属于正式 TV，但保持原地；
- `D:\Jellyfin-Repro` / `test`：2 个视频，仅测试；
- 正式 TV 总量：676；
- 全部 `tvshows`：678。

因此 **634 是 D 盘 View scope，不是全部生产 TV**。后续生产切换只替换 9 个 D 盘 TV roots，`C:\bangumi` 继续作为独立正式库保留。

## v2：文件层已完成，Jellyfin 验证基本成功

v2 完整 View 已在真实 Windows/NTFS 上 Apply 并通过二次幂等检查：

```text
Source files:       1227
Source videos:      634
Correction targets: 243
Reusable rows:      1227
Rows to create:     0
Conflicts:          0
```

v2 验证库 `D:\Resource\BangumiLink\View\2026年1月新番` 中：

- 186 个物理视频全部可追踪；
- normal Episode 从原库的 120 提升到 181；
- 剩余 5 个差值全部是真实多版本；
- 因此原来的错误 hidden / `LocalAlternateVersion` 合并问题基本解决。

v2 同时暴露了三类集中残留：四个 Series 网络身份不稳定、《名探偵プリキュア！》单集目录形成额外 Season、78 个语言后缀字幕未跟随 correction video。

## v3：文件层与结构验证均已完成

入口：

```text
scripts/apply_jellyfin_full_canonical_view_v3.py
```

固定目标：

```text
View:     D:\Resource\BangumiLink\View-v3
Manifest: D:\Resource\BangumiLink\Logs\full-manifest-v3.csv
```

v3 只增加已由真实验证证明需要的局部规则：

- Fate/strange Fake、Medalist 第2期、【推しの子】第3期、芙莉莲第2期使用明确 TMDB ID 的 canonical Series 目录；
- 《名探偵プリキュア！》correction 正片压平到 `Season 01`；
- NCOP/ED 进入 `extras`；
- correction sidecar 支持 `video.chs.ass` / `video.cht.ass` 等语言后缀形式。

真实 v3 Apply：

```text
Build id:     20260814-211137-174767
Created rows: 1227
Reused rows:  0
Manifest:     D:\Resource\BangumiLink\Logs\full-manifest-v3.csv
```

实际 manifest 独立核验：

```text
CORRECTION_VIDEO:   243
CORRECTION_SIDECAR: 321
PASSTHROUGH_VIDEO:  391
PASSTHROUGH_FILE:   272
HARDLINK:           738
COPY:               489
SourcePath duplicates:    0
CanonicalPath duplicates: 0
```

其中 321 个 correction sidecar = 243 NFO + 78 个语言后缀 ASS；光美 54，Clevatess 24。光美 113 行 canonical 路径只落在 `Season 01`（112）和 `extras`（1）。

Apply 后真实二次 dry-run：

```text
Reusable rows:      1227
Rows to create:     0
Conflicts:          0
```

随后建立 `验证-v3-2026年1月`，只挂载 `View-v3\2026年1月新番`。真实 Jellyfin 12 扫描结果：

```text
Filesystem videos:  186
Expanded Episodes:   185
Normal Episodes:     180
```

正确解释：175 个 Episode 各 1 个版本，5 个 Episode 各 2 个真实版本，共 185 个 Episode media paths；第 186 个物理视频是已经正确放进 `extras` 的光美 NCOP，不再属于 Episode。

同时：

- 光美原先 27 个额外 Season-like 容器消失；
- NCOP 不再冒充 S01E11；
- Fate / Medalist / 我推 / 芙莉莲四个 Series provider identity 均已正确；
- 剩余标题和 Overview 缺失已经是 metadata/provider lookup 问题，不是 canonical path 结构问题。

因此 **v3 构建器和路径布局到此冻结，不再为 metadata 问题制造 v4。**

## 当前下一步：Episode metadata（Issue #5）

当前集中残留：

- 芙莉莲 Season 2、我推 Season 3 的 Series 已正确识别，但 Season provider identity 为空，Episode Name 仍是 canonical 文件名，Overview 只部分获得；
- FSF Season 1 正常，但 Season 0 / `Whispers of Dawn` 无 Episode provider metadata；
- correction NFO 仍是只写 Season/Episode 的 sparse NFO。

下一步只做 metadata 层的受控实验和修复，不再改变 canonical layout。生产切换仍只涉及 9 个 D 盘 TV roots；`C:\bangumi` 保持原样。

## 安全边界

始终保持：

- 原始收藏不移动、不重命名、不删除；
- `C:\bangumi` 42 个正式杂项 TV 不进入 D 盘 hardlink View；
- 不直接写 Jellyfin SQLite；
- 不自动修复全部 33 个 non-target hidden/extras；
- Episode 标题、Overview、Provider metadata 与 canonical 文件布局分层处理；
- 生产 roots 切换前仍需单独确认切换策略；
- 真实结论以本地 Windows + NTFS + Jellyfin 12 输出为准。
