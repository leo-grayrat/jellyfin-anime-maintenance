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

## 处理对象与唯一定位规则

脚本不做模糊搜索。每个目标同时固定“一级分组目录 + Series 目录名前缀”，并要求该分组下恰好只有一个直接子目录符合前缀。

| 一级分组目录 | Series 目录名前缀 | 写入的干净标题 | TVDB | TMDB | IMDb |
|---|---|---|---:|---:|---|
| `2017年动画` | `[JYFanSub][Youjo Senki]` | 幼女战记 | 315500 | 69346 | tt6455986 |
| `2023年动画` | `[Nekomoe kissaten&VCB-Studio] THE IDOLM@STER CINDERELLA GIRLS U149` | 偶像大师 灰姑娘女孩 U149 | 424278 | 216391 | tt26699386 |
| `2025年4月新番` | `[Prejudice-Studio] 前桥魔女 Maebashi Witches` | 前桥魔女 | 454132 | 270602 | tt35351289 |
| `2025年7月新番` | `[DBD-Raws][克雷瓦提斯-魔兽之王与婴儿与尸之勇者-]` | 克雷瓦提斯-魔兽之王与婴儿与尸之勇者- | 451793 | 258348 | tt32991344 |
| `2025年7月新番` | `[Nekomoe kissaten&LoliHouse] Ruri no Houseki` | 瑠璃的宝石 | 454330 | 271649 | tt37113118 |
| `2025年10月新番` | `[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26` | 藤本树 17-26 | 467641 | 299778 | tt38491451 |
| `2025年10月新番` | `SPY×FAMILY Season 3` | SPY×FAMILY | 405920 | 120089 | tt13706018 |

如果某个分组不存在、某个前缀匹配 0 个或多个目录、命中项不是直接子目录、命中项是符号链接，或者结果路径不在 `View-v3` 内，则整个预检失败，不写任何文件。

## 文件形式

每部作品目录只新增一个最小 `tvshow.nfo`：

```xml
<tvshow>
  <title>干净的中文标题</title>
  <uniqueid type="tvdb">...</uniqueid>
  <uniqueid type="tmdb">...</uniqueid>
  <uniqueid type="imdb">...</uniqueid>
</tvshow>
```

只保存：

- 上表明确指定的干净标题；
- TVDB ID；
- TMDB ID；
- IMDb ID。

这里的 `<title>` 是有意固定的本地显示标题，目的就是避免身份退化时再次把字幕组发布目录名当成 Series 名。它不依赖远程数据库再次决定标题。

明确不写：

- Overview / 简介；
- Season / Episode 数量；
- 分集标题；
- 图片；
- `displayorder`；
- 任何自动刷新策略字段。

这样做的目的，是只固定作品身份和最低限度的显示标题，不把远程简介、分集信息和图片复制成本地静态副本。

## 实现

新增脚本：

`scripts/write_jellyfin_series_identity_nfos.py`

### 输入

- `--view-root`：默认 `D:\Resource\BangumiLink\View-v3`
- 默认 dry-run
- `--apply`：实际写入

脚本不需要 Jellyfin API key，因为本步骤只处理本地整理目录中的 7 个 `tvshow.nfo`。

### 目标定位

脚本内部保存上表的 7 条固定对应关系。对每条关系：

1. 进入指定一级分组目录；
2. 只枚举该目录的直接子目录；
3. 以 `startswith()` 匹配指定前缀；
4. 必须恰好命中 1 个真实目录；
5. 再确认命中路径仍位于 `View-v3` 内。

不跨分组搜索，不递归猜测，不根据相似作品名自动选择。

### 现有文件处理

- 目标目录没有 `tvshow.nfo`：状态 `CREATE`。
- 已有 `tvshow.nfo` 且内容与计划完全一致：状态 `REUSE`。
- 已有 `tvshow.nfo` 但内容不同：状态 `CONFLICT`，默认拒绝覆盖。

只要 7 部中任意一部出现 `CONFLICT`、找不到或多匹配，整个 Apply 都拒绝开始。本步骤不自动合并或覆盖未知的 Series NFO。

### 写入方式

`--apply` 前重新执行一次完整预检。

实际写入采用：

1. 在目标目录写同目录临时文件；
2. 写完并关闭；
3. 原子替换到 `tvshow.nfo`；
4. 全部完成后重新读取 7 个目标 NFO，逐字确认内容与计划一致。

写入 UTF-8 文本。

## 输出

Dry-run 必须显示全部 7 部作品各自：

- 分组目录；
- 实际命中的 Series 目录；
- 写入标题；
- TVDB / TMDB / IMDb；
- `CREATE / REUSE / CONFLICT` 状态。

正常首次运行应当是 7 个确定目标，且没有未解析或重复目标。

`--apply` 只有在完整预检通过时才允许写入；写入后再次验证 7 个文件，全部一致才打印成功。

## 安全边界

本步骤明确不会：

- 改原始动画文件；
- 改 `View-v3` 中任何视频或字幕；
- 重命名 Series 目录；
- 修改 Episode NFO；
- 删除已有文件；
- 覆盖内容不同的现有 `tvshow.nfo`；
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
4. Episode 元数据能够继续由启用的远程元数据来源补全；
5. 2026 年已正常的作品不发生变化；
6. 日志中不再出现由 `Missing Episode Fetcher` 导致的那批虚拟 Season / Episode 增删行为。

如果扫描后 7 部仍然发生身份退化，则说明问题不只是“缺少本地 Series 身份”，届时再根据审计结果继续查，不扩大写入范围。
