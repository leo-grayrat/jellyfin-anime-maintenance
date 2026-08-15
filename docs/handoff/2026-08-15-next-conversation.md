# 2026-08-15 下一对话交接提示词

下面整段可以直接交给下一次 ChatGPT / AI 对话继续工作。

---

你现在接手 GitHub 仓库：

```text
https://github.com/leo-grayrat/jellyfin-anime-maintenance
```

当前主要工作分支仍是：

```text
feat/tv-audit-export
```

开始前先检查仓库当前 `main`、该工作分支、README、`docs/history/`、`docs/handoff/`、open issues 和最近提交。不要假定这份交接之后仓库没有变化。

特别注意：此前用户曾在 **main 上单独修改 README**。以后合并分支时必须确认 main 上需要保留的 README 内容没有被旧分支覆盖。不要机械用分支版本覆盖 main。

请同时阅读：

```text
docs/handoff/2026-08-15-project-story.md
```

本文件回答“现在在哪里、下一步具体做什么”；story 文档回答“为什么项目会走到这里、哪些弯路不要重走”。

---

## 一、现在的主线已经彻底改变：不要继续给 View-v3 打补丁

到 2026-08-15 晚上，用户已经明确决定停止继续修补当前 Jellyfin 数据库、旧 View-v3、零散 NFO 和手动刷新状态。

新的主线是：

> **从真实源文件重新开始，把每一个视频到底是什么先判断清楚，再建立一批新的硬链接整理库。**

核心工作流是：

```text
真实源文件名 / 所在目录
        ↓
人或大语言模型逐项判断内容身份
        ↓
形成明确、可审阅的映射表
        ↓
脚本只负责照表创建硬链接 / 必要 sidecar
        ↓
全新的 Jellyfin 媒体库首次扫描
```

不要再反过来：

```text
先写一个越来越复杂的正则脚本
→ 让脚本猜字幕组文件名
→ 发现例外
→ 再补规则
→ 再刷新 Jellyfin
```

用户已经明确指出，这条路线最后会变成一坨难维护的补丁。

**下一步首先是继续做人工/模型判定表，不是继续写 Jellyfin 修复脚本。**

---

## 二、用户已经明确的协作方式，务必遵守

这些不是“偏好建议”，而是本项目已经反复踩过坑后的工作规则。

### 1. 没有大问题不要反复请示

用户已经多次明确：

- 已经同意的方向，直接继续；
- 普通实现细节自己选最合理方案；
- 写一份设计文档不等于重新出现审批点；
- 只有真正改变数据安全边界、删除/重建重要数据、扩大操作范围等重大节点才停下来问。

不要出现：

```text
用户：同意
AI：我先写设计文档
AI：设计写好了，你再确认一次
```

### 2. 不要在云端做“假本地验证”

用户真实环境是 Windows + Jellyfin 12.0.0。云端没有他的文件系统、Jellyfin 数据库和真实扫描行为。

因此：

- 可以做语法检查、纯逻辑测试、明显静态检查；
- Windows 路径、Jellyfin API、扫描/刷新结果，以用户本机为准；
- 不要在临时目录模拟一个“假 Jellyfin 环境”后宣布验证成功；
- 不要天天算 hash、Git blob SHA 来证明没冲突。当前不是多人并发的大工程，这种仪式没有价值。

### 3. Python 优先，PowerShell 只做短命令

本项目早期 PowerShell 多次因转义、长路径、Windows PowerShell 5.1 行为出错。后来复杂逻辑迁到 Python 后明显稳定。

默认：

- 新复杂逻辑优先 Python；
- PowerShell 只用于很短、很直白的本机命令；
- 不要因为旧脚本是 PowerShell 就继续堆 PowerShell。

### 4. 说人话，不要堆英文术语

优先说：

- “整理后的 View 目录”
- “硬链接整理库”
- “映射表”
- “分集身份”
- “附加视频”

必要的 Jellyfin/API 固有字段可以保留英文，但不要把简单事情包装成术语表演。

### 5. 终端输出重复时，不要推断用户真的执行了两遍

本轮已经确认：ChatGPT 输入框 / Typeless / 浏览器插件链路会把整块终端内容重复插入。用户后来上传原始 txt，证明本地只执行了一次，但聊天输入里出现了两份。

所以：

> **同一条消息里出现大段高度相同终端文本，默认视为输入重复；除非命令、时间戳或状态真的不同，否则不要构造“用户又运行了一次”的时间线。**

### 6. 不要保存或复述旧 API Key

聊天中曾出现真实 Jellyfin API Key，用户已表示会销毁换新。不要把任何旧 key 写入仓库、issue、交接文档或回答。

---

## 三、真实环境与源文件

Jellyfin：

```text
Version: 12.0.0
Server: http://127.0.0.1:8096
```

真实源媒体至少包括：

```text
D:\Bangumi\...
C:\bangumi\...
D:\Gekijouban\...
```

用户不希望为了 Jellyfin 重命名、搬动、破坏原始收藏。

新的整理方案仍然通过硬链接建立独立结构。

### C 盘整理根目录已经锁定

用户明确指定：

```text
C:\resource\video\anime
```

不要写成：

```text
C:\BangumiLink
C:\anime
```

也不要直接污染 C 盘根目录。

### D 盘新整理根目录尚未最终锁定

旧实验产物主要在：

```text
D:\Resource\BangumiLink\View\
D:\Resource\BangumiLink\View-v3\
D:\Resource\BangumiLink\Logs\
```

但新一代整理库不要擅自假定必须叫 `View-v4`。先把映射表完成，再选一个清楚、稳定的 D 盘根目录。

### 硬链接不能跨卷

C 盘源文件只能在 C 盘目标创建硬链接；D 盘源文件只能在 D 盘目标创建硬链接。

最终一个 Jellyfin 逻辑媒体库可以挂 C/D 两边多个路径，因此“2025年04月新番”等逻辑库仍可同时包含两个卷上的整理目录。

---

## 四、下一步所需的权威输入：`anime-video-files.txt`

用户已经导出并上传：

```text
anime-video-files.txt
```

内容是三个源根下所有视频文件的真实完整路径，总计 **720 个视频文件**。

如果新对话里附件不可见，优先从 File Library 搜索这个文件；找不到再请用户重新上传。不要用旧 Jellyfin 数据库导出来的 Series/Episode 状态代替它，因为 Jellyfin 本身已经把 Menu、NCOP、特典等识别错过。

判定依据优先级：

```text
源文件名
→ 所在目录上下文
→ 字幕组命名规律
→ TVDB / TMDB 的实际作品与特别篇结构
→ 最后才参考当前 Jellyfin 识别
```

### 建议形成一张明确映射表

字段至少应包括：

```text
SourcePath
WorkTitle
LibraryGroup
MediaClass
Season
Episode
SpecialType
VersionGroup
TargetRelativePath
DecisionBasis
Status
```

其中 `MediaClass` 不要只做“正片/非正片”两类，至少区分：

```text
TV_EPISODE
TV_SPECIAL
MOVIE
EXTRA_NCOP
EXTRA_NCED
EXTRA_PV
EXTRA_CM
EXTRA_MENU
EXTRA_MV
EXTRA_OTHER
ALT_VERSION
```

映射表的内容由人/模型判断，脚本只执行，不要把判断逻辑重新塞回脚本。

---

## 五、已经确认的几个具体归属规则

这些在下一轮不要重新从零猜。

### 1. Do It Yourself!!

用户已明确：

```text
Do It Yourself!! → 2022年动画
```

**不是** `2022年10月新番`。

目前 C/D 两边各有一套正篇来源：

- `C:\bangumi\[SweetSub&VCB-Studio] Do It Yourself!! ...`
- `D:\Bangumi\2022\[SweetSub] Do It Yourself!! ...`

C 盘版本还带：

```text
NCOP01
NCOP02
NCED
```

这些是 BD 附加视频，不是 Episode。

两套正篇是同一作品的重复来源，最终不要在 Jellyfin 里做成两个独立 Series。如何保留/选择版本应在映射表里明确。

### 2. C 盘另外两部“杂项 TV”应归回正常季度

```text
Sousei no Aquarion - Myth of Emotions → 2025年01月新番
Mobile Suit Gundam GQuuuuuuX          → 2025年04月新番
```

GQuuuuuuX 的 `Bonus` 目录是额外视频，不是正篇 Episode。

### 3. BDRip 不等于“正片”

用户特别提醒：TV 和剧场版的 BDRip 文件夹里经常包含大量 BD 附送内容。

例如可能有：

```text
SP
OVA
NCOP
NCED
PV
CM
Menu
Information
Tokuten / 特典映像
特典动画
MV
Theater Preview
Theater Manner
```

判断时必须看文件名和内容语义，而不是看到 `BDRip` 就当作正篇。

### 4. “BD 附送”也不等于一律放 extras

有些 BD 附送动画本身就是数据库正式收录的特别篇。

需要逐项区分：

- 正式有剧情、TVDB 收录为 Special 的动画 → 可以进入 `Season 00`；
- NCOP/NCED/PV/CM/Menu/Information 等 → 附加内容；
- 模糊的 `SP` / `特典动画` → 结合标题和数据库确认。

不要做“一刀切”。

### 5. 幼女战记 2017 的 `[SP]`

原目录里 `[00][SP]` 到 `[12][SP]` 是一组迷你动画，不是普通 NCOP/菜单。

此前核对 TVDB 后确认它们属于正式 Specials，应映射到 `Season 00`，而不是直接丢进 extras。

注意 TVDB 的 Special 编号中间还夹了别的条目，因此不能简单机械 `#07 → S00E08`，要按数据库实际编号建立映射。

### 6. U149 的 OVA

```text
[Nekomoe kissaten&VCB-Studio] THE IDOLM@STER CINDERELLA GIRLS U149 [OVA]...
```

这是正式特别篇，不是普通附加视频；但具体 TVDB Special 编号还需要下一轮确认后写入映射表。

### 7. 100 女友跨季全局编号

2025 BDRip 文件写成：

```text
S01E13 ... S01E24
```

实际应按第二季重新映射成：

```text
S02E01 ... S02E12
```

2026 新一批 25、26……对应第三季 E01、E02……，不要继续沿用全局 Episode 数当 Season 1。

### 8. Frieren / SPY×FAMILY / Medalist 的全局编号

已知存在“字幕组用全局话数，但 Jellyfin/TVDB 用分季编号”的情况：

- Frieren 第二季的 29–38 → S02E01–S02E10；
- SPY×FAMILY 第三季的 38、39…… → S03E01、S03E02……；
- Medalist 第二季的 14、15…… → S02 对应集数。

有些作品同时存在全局编号版本和已经写明 `S2 02` 之类的另一字幕组版本。不要把不同字幕组版本误删成重复文件；要在映射表里标成同一 Episode 的不同版本。

### 9. `v2` 与不同字幕组版本

同字幕组同一集 `08` / `08v2` 一般把 `v2` 视为修正版；不同字幕组同一集则保留为不同版本。

不要自动删除任何原文件，映射表只决定整理层怎么呈现。

---

## 六、剧场版与“看起来像电影、其实不是电影”的条目

`D:\Gekijouban` 也要在这次新整理里一起处理，不能再单独放任 Jellyfin 猜。

已经明确的几个典型：

### 1. 剧场版幼女战记

正片是电影；同目录的：

```text
CM
Main PV
Menu
Information
Theater Preview
Theater Manner
```

不能再被 Jellyfin 当成多部同名电影。

原则上这些应作为电影附加视频，除非某个内容本身有明确理由作为 TV Special。不要机械迁就数据库里“只要有条目就当 Episode”的做法。

### 2. Chainsaw Man - The Compilation - 01/02

此前核对后确认它们不是两部普通电影，而是《链锯人》的正式特别篇/总集篇，应归回 TV 作品的 `Season 00`。

### 3. Kaguya-sama ... Otona e no Kaidan - 01/02

属于《辉夜大小姐》的正式两话特别篇，应归 TV，不应留在电影库里当两部电影。

### 4. HELLO WORLD / ANOTHER WORLD

`ANOTHER WORLD - 01/02/03` 不是电影花絮，而是独立的三话衍生动画系列。整理时应作为独立 TV/短篇 Series，而不是塞在电影 extras。

### 5. Chou Kaguya-hime

`[Movie]` 是电影正片，`[MV]` 是该电影附加 MV。

### 6. THE RIBBON HERO 2026

是独立电影正片。

这些结论在真正生成映射表时仍应保留 `DecisionBasis`，避免以后忘记为什么这样分。

---

## 七、为什么现在不再继续修旧 Jellyfin 数据库

### 1. View-v3 之前确实解决了“路径解析”类问题

旧主线发现 Jellyfin 会看完整路径，祖先目录的：

```text
2026-01
2026-07
```

等数字结构可能参与 Episode 解析，导致 LocalAlternateVersion 等错误。

通过新硬链接 View，把文件显式命名为：

```text
S02E09 - 原字幕组文件名.mkv
```

能够稳定规避这类路径解析问题。

这条经验仍然有效，新整理库也应保留“显式 SxxEyy”的思想。

### 2. View-v3 已经建立成功，但现在冻结

旧 View-v3：

```text
D:\Resource\BangumiLink\View-v3
```

当时覆盖 9 个 D 盘生产 TV root，共：

```text
Source videos:       634
Source files:        1227
Correction targets:  243
HARDLINK rows:       738
COPY rows:           489
```

第二次 dry-run 可 1227/1227 复用。

它解决了大部分结构解析，但后来暴露出 provider 模型、Series identity、Season/Episode 元数据刷新等另一层问题。

**现在不要继续往 View-v3 塞新补丁。保留它作为实验结果，直到新整理库验证成功。**

### 3. 原来 634 不是全部 TV

曾经有一次范围误解。最后确认：

```text
9 个 D 盘生产 TV roots: 634 视频
C:\bangumi 杂项 TV:      42 视频
D:\Jellyfin-Repro:         2 视频
全部 tvshows roots:      678 视频
```

新 `anime-video-files.txt` 则把 D/C TV + Gekijouban 全部真实视频路径一起导出，共 720 条。

---

## 八、TVDB / Series identity / NFO 这条支线的最终结论

### 1. TMDB 模型不适合部分本地季结构，不算 Jellyfin 核心 bug

例如：

- Frieren 第二季在 TMDB 上以独立 Series 存在；原 Series 的 S2 并不匹配本地；
- Oshi no Ko 的本地 S2/S3 与 TMDB 原 Series 的季结构不一致；
- Fate/strange Fake 的特殊篇结构也不同。

因此早先 `TmdbEpisodeProvider returned no metadata` 不能简单报 Jellyfin bug。

TVDB 对这些动画的季结构通常更符合本地期望。

### 2. 曾经有 7 部自动识别失败

分组库建立后，53 个 Series 中最初有 7 部没有正常自动识别：

1. 幼女战记
2. 偶像大师 灰姑娘女孩 U149
3. 前桥魔女
4. 克雷瓦提斯-魔兽之王与婴儿与尸之勇者-
5. 瑠璃的宝石
6. 藤本树 17-26
7. SPY×FAMILY Season 3

它们大多使用字幕组发布式 Series 文件夹名。

成功人工 Identify 后得到的真实身份：

| 作品 | TVDB | TMDB | IMDb |
|---|---:|---:|---|
| 幼女战记 | 315500 | 69346 | tt6455986 |
| 偶像大师 灰姑娘女孩 U149 | 424278 | 216391 | tt26699386 |
| 前桥魔女 | 454132 | 270602 | tt35351289 |
| 克雷瓦提斯-魔兽之王与婴儿与尸之勇者- | 451793 | 258348 | tt32991344 |
| 瑠璃的宝石 | 454330 | 271649 | tt37113118 |
| 藤本树 17-26 | 467641 | 299778 | tt38491451 |
| SPY×FAMILY | 405920 | 120089 | tt13706018 |

### 3. 已经为这 7 部在 View-v3 写了最小 `tvshow.nfo`

脚本：

```text
scripts/write_jellyfin_series_identity_nfos.py
```

只写：

```xml
<tvshow>
  <title>...</title>
  <uniqueid type="tvdb">...</uniqueid>
  <uniqueid type="tmdb">...</uniqueid>
  <uniqueid type="imdb">...</uniqueid>
</tvshow>
```

本机 Apply：

```text
Created 7 tvshow.nfo file(s). Verified 7 target(s) as REUSE.
```

它确实能帮助 Series 身份恢复，但没有自动把下面 Season/Episode 全部洗干净。

这也是最终决定放弃继续修旧库的重要原因之一。

---

## 九、七部作品的分层检查结果：证明“Series 认出来”不等于“下面正常”

专门写了只读检查脚本：

```text
scripts/inspect_jellyfin_seven_series.py
```

本机结果非常重要：

### 幼女战记

```text
series: identity / overview / image 正常
seasons=3 indexes=0,1,2
episodes=42
real file episodes 约 13，另有大量旧虚拟 missing episodes
```

### U149

```text
series 正常
有 1 个 OVA 条目没有 season/episode number / TVDB ID
另有 TVDB missing episode 虚拟项
```

### 前桥魔女

```text
Series identity 正常
Series overview 缺失
12 集都有 EpisodeNumber
但 SeasonNumber 全空
Episode TVDB ID 全空
标题仍像本地文件名
```

### 瑠璃的宝石

```text
Series identity 正常
Series overview 缺失
13 集都有 EpisodeNumber
SeasonNumber 全空
Episode TVDB ID 全空
Overview 全空
Jellyfin UI 显示“未知季”
```

### 藤本树 17-26

```text
Series identity 正常
Season 1 正常
8 集 S/E 数字正确
Episode TVDB ID 全空
Overview 全空
标题仍是本地文件名
```

### SPY×FAMILY

```text
Series identity 正常
Season 3 正常
13 集 S/E 数字正确
Episode TVDB ID 全空
Overview 只有一部分
标题仍是本地文件名
```

### Clevatess

有大量旧虚拟 missing episodes；同时 `menu / PV / NCOP&NCED / 特典映像` 等真实附加视频曾被误当成普通 Episode，说明“把 BD 目录交给 Jellyfin 自己猜”并不可靠。

这个检查最终促成主线转向：**先整理真实文件语义，再新建库。**

---

## 十、TheTVDB Missing Episode Fetcher：已经关闭，不要重新打开

日志里曾出现大量：

```text
SQLite Error 19: FOREIGN KEY constraint failed
```

堆栈落到：

```text
Jellyfin.Plugin.Tvdb.Providers.TvdbMissingEpisodeProvider
```

现象是在库删除/扫描期间，父 Season/Series 正在被移除，Missing Episode Fetcher 又尝试创建虚拟 Season/Episode，发生 FK race。

仓库已有：

```text
scripts/disable_jellyfin_missing_episode_fetcher.py
```

用户本机最后确认：

```text
Libraries: 9
To update: 0
Already disabled: 9
```

所以当前 9 个分组库已经关闭该功能。

注意：关闭只阻止继续新增，不会清掉旧虚拟项。新建全新媒体库时不要再开启它。

---

## 十一、当前值得保留的 Jellyfin 上游 issue 候选

用户刚刚特别纠正：讨论“有没有新 issue”时，重点是**最近发现的安全刷新合并行为**，不要又把所有旧 issue 重讲一遍。

### 候选 A：普通安全刷新无法纠正已经非空的 Episode Name

当前观察：

- Episode 初始 Name 来自本地文件名；
- provider 后续能拿到正确远端元数据；
- `ReplaceAllMetadata=false` 时，Jellyfin 的合并逻辑对已有非空 `Name` 不覆盖；
- 因此 ID、简介等可能补进来，但错误的文件名标题继续保留；
- 要覆盖 Name 又必须使用更破坏性的 `ReplaceAllMetadata=true`。

已经专门搜索过 Jellyfin issue：

- **没有找到完全对应“Episode 文件名标题无法被普通刷新纠正”的现成 issue**；
- 但 Jellyfin #14080 是很接近的先例：provider 已返回正确 `ParentIndexNumber`，已有非空值因为 `replaceData=false` 挡住更新。

所以新库第一次扫描后，如果仍能做出干净复现，这个很值得新报 issue。

### 候选 B：ReplaceAllMetadata + provider 不完整时会清掉已有 Overview，但 Name 又受到特殊保护

Medalist 单集实验中观察到：

- `replaceAllMetadata=true`；
- provider 某些字段为空；
- Overview 被清掉；
- Name 又没有同样被清空。

这是另一个候选，仓库已有历史记录。不要和候选 A 混为一谈。

### 候选 C：TVDB Missing Episode Fetcher 的 FK race

插件在父条目删除/刷新期间创建虚拟子条目，日志中出现大量 FK constraint failure。已有相关 Missing Episode Fetcher 问题，但我们这条具体 race 是否已有完全相同报告尚未最终确认。

### 不再当 Jellyfin core bug 的方向

TMDB Episode `returned no metadata` 在 Frieren / Oshi 等案例已证明主要是外部数据库结构模型不匹配，不能再当 Jellyfin 核心 bug 追。

---

## 十二、已有主要脚本，知道即可，不要继续无限扩张

目前仓库主要相关脚本包括：

```text
scripts/build_jellyfin_full_canonical_view.py
scripts/apply_jellyfin_full_canonical_view_v3.py
scripts/create_jellyfin_grouped_libraries.py
scripts/audit_jellyfin_series_identity.py
scripts/disable_jellyfin_missing_episode_fetcher.py
scripts/write_jellyfin_series_identity_nfos.py
scripts/inspect_jellyfin_seven_series.py
```

它们记录了此前调查和实验能力，但新的主线不应该继续围绕它们叠补丁。

映射表完成之后，才新增一个很笨、很透明的“manifest executor”即可：

```text
读取固定映射表
→ 检查源文件存在
→ 检查同卷
→ 创建目标目录
→ 创建硬链接
→ 复制必要 sidecar
→ 冲突即拒绝
```

**它不应该再自己猜作品、季号、SP、OVA、NCOP。**

---

## 十三、真正的下一步

下一模型接手后直接做下面这些，不要再绕回旧库刷新：

1. 找到用户上传的 `anime-video-files.txt`（720 行真实视频路径）。
2. 继续逐项阅读文件名和目录上下文。
3. 先建立可审阅的人工判定映射表。
4. 重点把以下几类全部清楚拆开：
   - TV 正篇；
   - 正式 Season 00 特别篇；
   - OVA/OAD；
   - NCOP/NCED；
   - PV/CM/Menu/Information/MV；
   - BD 特典动画；
   - 剧场版正片；
   - 剧场版附加视频；
   - 同一集不同字幕组版本；
   - v2 修正版；
   - 全局话数 → 分季话数转换。
5. 对仅靠文件名仍不明确的少数项目，再查 TVDB/TMDB。
6. 不要在映射表尚未基本完成前写“聪明解析器”。
7. 映射表稳定后，再写一个简单脚本照表创建新硬链接整理库。
8. 新库建完后，用全新 Jellyfin 媒体库首次扫描验证。
9. 只有在新库能干净复现元数据合并问题时，再考虑整理上游 issue。

---

## 十四、安全边界

### 可以直接做

- 读仓库、日志、CSV、上传清单；
- web / GitHub 搜索 TVDB/TMDB/Jellyfin issue；
- 建立/修改映射表和说明文档；
- 写 dry-run 工具；
- 修改当前 feature branch；
- 只读 Jellyfin audit。

### 默认不要做

- 不移动/重命名/删除 `D:\Bangumi`、`C:\bangumi`、`D:\Gekijouban` 原文件；
- 不直接写 Jellyfin SQLite；
- 不继续手动刷新旧 View-v3 作为主线；
- 不重新开启 Missing Episode Fetcher；
- 不删除旧 View-v3，直到新库验证完成；
- 不把用户完整私人媒体清单、API key 公开提交到仓库。

真正涉及删除/重建 Jellyfin 现有媒体库、可能影响观看状态时，属于应该停下来告知用户的重大操作。

---

## 十五、最后一句：不要把“脚本写出来”当成项目目标

这个项目已经用很长一段路证明：

> **字幕组命名本身包含大量语义。最可靠的办法不是逼脚本发明越来越复杂的猜测规则，而是先把真实收藏理解清楚，再让脚本机械执行已经确认的事实。**

下一步请从 `anime-video-files.txt` 和映射表继续，而不是从旧 Jellyfin UI 的一条坏元数据继续打补丁。
