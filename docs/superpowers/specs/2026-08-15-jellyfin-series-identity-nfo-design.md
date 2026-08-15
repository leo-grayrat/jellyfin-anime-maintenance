# 七部未稳定识别动画的 Series 身份固定设计

日期：2026-08-15
分支：`feat/tv-audit-export`

## 目标

只处理最初自动识别失败、后来手工识别后仍发生身份退化的 7 部动画。目标不是保存完整元数据，而是把“这是什么作品”这一层身份固定在整理后的 `View-v3` 目录里，使 Jellyfin 后续重新扫描时仍能从本地文件恢复正确的远程数据库身份。

本设计不处理其他 46 部已稳定识别的动画，也不修改 2026 年已正常工作的目录。

## 已确认前提

- 9 个动画库中的 `Missing Episode Fetcher` 已经全部关闭。
- TheTVDB 正常的元数据和图片抓取器继续保留。
- 这 7 部作品的正确 IMDb / TMDB / TVDB ID 已从实际手工 Identify 成功时的 Jellyfin 日志中确认。
- 现有问题集中在这 7 部；2026 年那批动画没有出现同样的元数据退化。

## 处理对象

| 作品 | TVDB | TMDB | IMDb |
|---|---:|---:|---|
| 幼女戦記 | 315500 | 69346 | tt6455986 |
| THE IDOLM@STER CINDERELLA GIRLS U149 | 424278 | 216391 | tt26699386 |
| 前橋ウィッチーズ | 454132 | 270602 | tt35351289 |
| Clevatess | 451793 | 258348 | tt32991344 |
| 瑠璃の宝石 | 454330 | 271649 | tt37113118 |
| 藤本タツキ 17-26 | 467641 | 299778 | tt38491451 |
| SPY×FAMILY | 405920 | 120089 | tt13706018 |

## 文件形式

每部作品目录只新增一个最小 `tvshow.nfo`：

```xml
<tvshow>
  <title>作品标题</title>
  <uniqueid type="tvdb">...</uniqueid>
  <uniqueid type="tmdb">...</uniqueid>
  <uniqueid type="imdb">...</uniqueid>
</tvshow>
```

只保存：

- 干净作品标题；
- TVDB ID；
- TMDB ID；
- IMDb ID。

明确不写：

- Overview / 简介；
- Season / Episode 数量；
- 分集标题；
- 图片；
- `displayorder`；
- 任何自动刷新策略字段。

这样做的目的，是只固定作品身份，不把远程元数据复制成本地静态副本。

## 实现

新增脚本：

`scripts/write_jellyfin_series_identity_nfos.py`

### 输入

- `--view-root`：默认 `D:\Resource\BangumiLink\View-v3`
- 默认 dry-run
- `--apply`：实际写入

脚本不需要 Jellyfin API key，因为本步骤只处理本地整理目录中的 7 个 `tvshow.nfo`。

### 目标定位

7 个目标不能依靠模糊搜索自动决定。脚本内部保存明确的作品对应表，并通过已知分组目录 + 已知现有 Series 目录名定位目标目录。

如果：

- 某个目标目录找不到；
- 同一目标匹配到多个目录；
- 目标路径跑出 `View-v3`；

则整个预检失败，不写任何文件。

### 现有文件处理

- 目标目录没有 `tvshow.nfo`：状态 `CREATE`。
- 已有 `tvshow.nfo` 且内容与计划完全一致：状态 `REUSE`。
- 已有 `tvshow.nfo` 但内容不同：状态 `CONFLICT`，默认拒绝覆盖。

本步骤不自动合并或覆盖已有 Series NFO，避免破坏未知的手工元数据。

### 写入方式

`--apply` 前重新执行一次完整预检。

实际写入采用：

1. 同目录临时文件；
2. 写完并关闭；
3. 原子替换到 `tvshow.nfo`。

写入 UTF-8 文本，不带额外 BOM 要求。

## 输出

Dry-run 显示 7 部作品各自：

- 分组库；
- 目标目录；
- 标题；
- TVDB / TMDB / IMDb；
- `CREATE / REUSE / CONFLICT` 状态。

`--apply` 完成后再次读取 7 个文件，确认内容与计划完全一致，才打印成功。

## 安全边界

本步骤明确不会：

- 改原始动画文件；
- 改 `View-v3` 中任何视频或字幕；
- 重命名 Series 目录；
- 修改 Episode NFO；
- 删除已有文件；
- 修改 Jellyfin 数据库；
- 调用 Jellyfin Identify；
- 自动触发媒体库扫描；
- 重新启用 `Missing Episode Fetcher`；
- 处理这 7 部之外的任何作品。

## 后续验证

脚本成功写入 7 个 NFO 后，再单独进行一次正常媒体库扫描，然后重新运行现有 Series 审计脚本。

判断成功的标准：

1. 7 部作品重新获得正确的 Series 身份；
2. 7 部的 TVDB / TMDB / IMDb 身份保持稳定；
3. Series 名不再退回字幕组发布目录名；
4. Episode 元数据能够继续由启用的远程元数据抓取器补全；
5. 2026 年已正常的作品不发生变化；
6. 日志中不再出现由 `Missing Episode Fetcher` 导致的那批虚拟 Season / Episode 增删行为。

如果扫描后 7 部仍然发生身份退化，则说明问题不只是“缺少本地 Series 身份”，届时再根据审计结果继续查，不扩大写入范围。