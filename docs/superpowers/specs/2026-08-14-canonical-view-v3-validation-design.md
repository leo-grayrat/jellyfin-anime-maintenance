# Canonical View v3 验证设计

## 目标

在不改动当前已验证的 `D:\Resource\BangumiLink\View`（v2）的前提下，生成一个并行 `View-v3`，只修复 2026-01 真实验证暴露出的残留问题，并再次交给 Jellyfin 独立验证。

## 已确认事实

- 2026-01 原库：186 个物理视频只有 120 个 normal Episode。
- v2 验证库：186 个物理视频对应 181 个 normal Episode；剩余 5 个差值均为真实多版本，因此核心 hidden/alternate 结构问题已经解决。
- v2 的残留问题集中为：
  1. Fate/strange Fake、Medalist 第2期、【推しの子】第3期、葬送のフリーレン第2期自动 Series 匹配失败/误匹配；
  2. 名探偵プリキュア！保留“一集一个子目录”，生成 27 个额外 Season；
  3. 该作品的 `NCOP_ED_01` 被误当成正片 Episode；
  4. `video.chs.ass` / `video.cht.ass` / `video.sc.ass` / `video.tc.ass` 这类语言后缀字幕没有跟随 correction video 的 `SxxEyy` canonical 名称。

## v3 规则

### 1. v2 保持冻结

默认 layout 仍为 `v2`。不修改现有 View，不迁移或删除任何 v2 文件，也不改现有 `full-manifest-v2.csv`。

### 2. 四个 Series 只在 v3 中固定 TMDB 身份

仅对 `2026年1月新番` 下这四个目录追加 Jellyfin 官方支持的 `[tmdbid-...]`：

- `Fate strange Fake (2026)` → `229858`
- `メダリスト 第2期 (2026)` → `237529`
- `【推しの子】 第3期 (2026)` → `203737`
- `葬送のフリーレン 第2期 (2026)` → `209867`

不推广到其他 Series。

### 3. 光美只在 v3 中压平 correction 正片

`名探偵プリキュア！ (2026)` 的 27 个 `precure` correction target，以及与其匹配的 NFO/字幕，统一进入：

`名探偵プリキュア！ (2026)\Season 01\S01Eyy - <原文件名>`

不保留 `[FLsnow]...[yy][1080p]` 单集目录层。

`NCOP_ED_01` 不编号，进入：

`名探偵プリキュア！ (2026)\extras\<原文件名>`

### 4. 语言后缀 sidecar

v3 sidecar 匹配从“最终 stem 完全相同”扩展为：

- `video.nfo`
- `video.ass`
- `video.chs.ass`
- `video.cht.ass`
- `video.sc.ass`
- `video.tc.ass`
- 以及同样以 `video.` 开头的非视频 sidecar

这些文件跟随 correction video 的 `SxxEyy` 和必要的光美压平路径。v2 继续保持旧的 exact-stem 行为。

## 并行构建与安全边界

- v3 必须写入独立 `View-v3`，不能覆盖默认 v2 View。
- v3 使用独立 manifest（默认 `full-manifest-v3.csv`），不继承 Phase 1 manifest，因为 canonical 路径已经改变。
- 原始媒体永不 rename/move/delete/overwrite。
- 视频和字幕继续 hardlink；NFO/图片/其他 metadata 继续 copy。
- 仍然不会自动切换生产 Jellyfin 媒体库。

## 成功标准

1. v3 preflight：634 source videos、243 correction targets、0 conflicts。
2. v3 Apply 后再次 preflight：全部行 reusable、0 create、0 conflicts。
3. Jellyfin 只挂 `View-v3\2026年1月新番` 验证：
   - 186 expanded physical video paths 全部可追踪；
   - normal Episode 仍为 181（5 个真实多版本差值）；
   - 光美只剩一个正常 Season 01，NCOP 不再成为 S01E11；
   - 四个 pinned Series 不再匹配到空身份或 `tt41541604`。
