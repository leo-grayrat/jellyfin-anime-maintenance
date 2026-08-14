# Jellyfin 规范视图

本仓库当前方案不是重命名原收藏，而是在 `D:\Resource\BangumiLink` 下为 Jellyfin 构建规范 View。调查已经确认：仅写 NFO 可以修正 Episode 自身的季号/集号，但 Jellyfin 可能在读取 NFO 之前就根据完整路径建立错误的 `LocalAlternateVersion`。因此需要同时规范 Jellyfin 看到的路径。

详细的 2026-08-14 实机过程记录见：

```text
docs/history/2026-08-14-full-canonical-view-validation.md
```

## 当前范围

真实 root 诊断已经闭合：

- 9 个 `D:\Bangumi` 正式 TV roots：634 个视频，进入 canonical View；
- `C:\bangumi` / `杂项TV动画`：42 个视频，属于正式 TV，但保持原地；
- `D:\Jellyfin-Repro` / `test`：2 个视频，仅测试；
- 正式 TV 总量：676；
- 全部 `tvshows`：678。

因此 **634 是 D 盘 View scope，不是全部生产 TV**。后续生产切换只替换 9 个 D 盘 TV roots，`C:\bangumi` 继续作为独立正式库保留。

只读范围诊断：

```powershell
python .\scripts\diagnose_jellyfin_tv_roots.py `
    --api-key "<API_KEY>"
```

## v2：完整 Full View，已经实机构建成功

当前已验证的 v2 入口：

```text
scripts/build_jellyfin_full_canonical_view.py
scripts/apply_jellyfin_full_canonical_view.py
```

只读 inventory / mapping：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

v2 对 634 个 D 盘视频生成 1227 行完整 mapping：

```text
CORRECTION_VIDEO:   243
CORRECTION_SIDECAR: 243
PASSTHROUGH_VIDEO:  391
PASSTHROUGH_FILE:   350
HARDLINK:           738
COPY:               489
```

写入脚本默认仍然是只读 preflight：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

2026-08-14 真实 Windows preflight：

```text
Source files:       1227
Source videos:      634
Correction targets: 243
Reusable rows:      486
Rows to create:     741
Conflicts:          0
```

随后真实执行：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>" `
    --apply
```

真实结果：

```text
Build id:     20260814-194819-395761
Created rows: 741
Reused rows:  486
Manifest:     D:\Resource\BangumiLink\Logs\full-manifest-v2.csv
Build log:    D:\Resource\BangumiLink\Logs\full-build-20260814-194819-395761.csv
```

第二次真实 dry-run：

```text
Reusable rows:      1227
Rows to create:     0
Conflicts:          0
```

因此 v2 文件层已经在真实 Windows/NTFS 上闭环。

v2 的基本写入策略：

- 视频和 `.ass/.ssa/.srt/.vtt/.sub/.idx`：同盘 hardlink；
- NFO、图片和其他普通文件：copy；
- 不移动、重命名、覆盖或删除原始媒体；
- 不写 Jellyfin SQLite；
- 不自动修改 Jellyfin production library root。

## v2 Jellyfin 独立验证结果

建立过独立验证库：

```text
验证-2026年1月
D:\Resource\BangumiLink\View\2026年1月新番
```

该目录有 186 个物理视频。第一次自然扫描后：

- 186 个物理路径全部能够在 Jellyfin expanded Episode / MediaSources 中追踪；
- normal Episode 为 181；
- 5 个差值全部是真实多版本：死亡游戏 E08 的 v1/v2，以及 Medalist E02～E05 的双版本；
- 原库同样 186 个物理视频时只有 120 个 normal Episode。

因此 v2 已经基本解决原来的错误 hidden / `LocalAlternateVersion` 合并问题。

验证同时暴露出三类集中残留：

1. Fate/strange Fake、Medalist 第2期、【推しの子】第3期、芙莉莲第2期的 Series 网络身份自动匹配不稳定；
2. 《名探偵プリキュア！》保留“一集一个子目录”，导致 1 个正确 Season 01 + 27 个额外 Season-like 容器，且 `NCOP_ED_01` 被误当成 S01E11；
3. `video.chs.ass` / `video.cht.ass` / `video.sc.ass` / `video.tc.ass` 等 78 个语言后缀字幕没有跟随 correction video 的 canonical 名称。

这些问题不推翻 v2 的主体结构，因此单独做 v3 验证，不覆盖已经验证成功的 v2。

## v3：并行 `View-v3`

v3 复用 v2 已验证的 Python 事务核心，但使用独立入口：

```text
scripts/apply_jellyfin_full_canonical_view_v3.py
```

固定目标：

```text
View:     D:\Resource\BangumiLink\View-v3
Manifest: D:\Resource\BangumiLink\Logs\full-manifest-v3.csv
```

v3 只增加已经由验证库证实需要的规则：

- 四个问题 Series 使用明确 TMDB ID 的 canonical Series 目录；
- 《名探偵プリキュア！》correction 正片压平到 `Season 01`；
- 该作品的 NCOP/ED 进入 `extras`；
- correction sidecar 支持 `video.chs.ass` 等语言后缀形式。

v3 不继承 Phase 1/v2 manifest，也不会修改 `D:\Resource\BangumiLink\View`。

### 当前 v3 实机状态

第一次 Windows dry-run 暴露过一个真实 Windows 路径 bug：脚本用空字符串表示“不继承 Phase 1 manifest”，在 Windows 长路径转换时触发 `ERROR: path must not be empty`。已改为合法但不存在的占位 manifest 路径。

修复后的真实 Windows preflight：

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

其中 sidecar `243 → 321` 与 78 个语言后缀字幕完全对应，总映射仍为 1227，当前没有 collision / conflict。

v3 尚未执行 `--apply`。下一步仍以真实 Windows 输出为准：

```powershell
python .\scripts\apply_jellyfin_full_canonical_view_v3.py `
    --api-key "<API_KEY>" `
    --apply
```

执行后应先再次运行不带 `--apply` 的 preflight，确认全部 reusable；随后再建立独立 Jellyfin v3 验证库。生产库切换仍然放在验证完成之后。

## 安全边界

当前始终保持：

- 原始收藏不移动、不重命名、不删除；
- `C:\bangumi` 42 个正式杂项 TV 不进入 D 盘 hardlink View；
- 不直接写 Jellyfin SQLite；
- 不自动修复全部 33 个 non-target hidden/extras；
- Episode 标题、Overview、Provider metadata 属于另一层问题，不和 canonical 文件布局混在一起；
- v2 / v3 验证完成前，不切换生产 Jellyfin roots；
- 真实结论以本地 Windows + NTFS + Jellyfin 12 输出为准，云端测试只能作为代码检查，不能替代实机验证。
