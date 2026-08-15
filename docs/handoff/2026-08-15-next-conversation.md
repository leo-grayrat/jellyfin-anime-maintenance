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

特别注意：此前用户曾在 **main 上单独修改 README，但没有把那次 README 修改提交到活动分支**。以后合并分支时必须确认 main 上需要保留的 README 内容没有被旧分支覆盖。不要机械用分支版本覆盖 main。

---

## 一、先理解当前真正目标：已经不再是继续给 View-v3 打补丁

这个项目最初只是想修 Jellyfin 对动漫季集号和字幕组文件名的识别问题，后来一路经历 NFO、LocalAlternateVersion、完整硬链接 View、元数据刷新、TVDB 等很多实验。

到 2026-08-15 晚上，用户已经明确改变主线：

> **不要再继续围着当前 Jellyfin 数据库和 View-v3 做一个又一个局部补丁。重新从真实源文件出发，把每一个视频到底是什么先判断清楚，再建立一批新的硬链接整理库。**

核心思想不是“写一个越来越聪明的正则脚本”，而是：

```text
真实源文件名 / 目录上下文
        ↓
人或大语言模型逐项判断内容身份
        ↓
形成明确、可审阅的映射表
        ↓
脚本只负责照表建立硬链接 / 复制必要 sidecar
        ↓
用全新的 Jellyfin 库首次扫描
```

脚本不应该继续承担“猜这个字幕组文件是什么”的职责。字幕组名称往往已经告诉我们 `SP`、`OVA`、`NCOP`、`NCED`、`PV`、`CM`、`Menu`、`特典映像`、集号、修正版 `v2` 等信息，大语言模型能够结合上下文逐项理解。

**下一步首先应继续完成这张人工判定表，而不是再写修补现有库的脚本。**

---

## 二、用户的工作方式要求——务必遵守

这些是本轮反复强调过的，不要再重犯。

### 1. 不要小事反复请示

用户已经多次明确：

- 已经同意的方向，直接继续；
- 普通设计细节自己选你认为最好的；
- 写一份设计文档不等于又出现一次审批点；
- 只有真正改变数据安全边界、明显扩大范围、删除/重建重要数据等重大节点才停下来询问。

不要出现：

```text
用户：同意
AI：我先写设计文档
AI：设计文档写好了，你再确认一下我才实现
```

这种流程用户非常厌烦。

### 2. 不要在云端做没有意义的“假本地验证”

用户的真实环境是 Windows + Jellyfin 12。云端没有他的文件系统、Jellyfin 数据库和真实 API 行为。

因此：

- 可以做基本语法检查、纯函数测试、明显逻辑检查；
- 真实 Jellyfin 输入输出、Windows 路径、扫描行为，以用户本机测试为准；
- 不要为了显得工程严谨，在临时目录搭假环境跑半天；
- 不要天天算文件 hash / Git blob SHA 来“证明文件没变”。这个仓库目前没有多人并发修改，除非真的需要校验来源，否则属于无用仪式。

### 3. Python 优先，PowerShell 谨慎

这一阶段曾经连续写出多份 PowerShell 脚本，出现正则转义、路径处理、Windows PowerShell 5.1 等问题。用户明确指出 GPT 写 PowerShell 在这个项目里错误率很高。

后来完整 View 工具迁到 Python 后稳定很多。

所以以后默认：

- 新的复杂逻辑优先 Python；
- PowerShell 只用于很短、很直白的本机命令或已有稳定脚本；
- 不要因为旧项目一开始是 PowerShell 就继续堆 PowerShell。

### 4. 语言要直白，不要没必要的英文术语

用户明确反感把简单概念反复叫 `canonical view` 等英文名。

优先说：

- “整理后的 View 目录”
- “硬链接整理库”
- “映射表”
- “分集身份”
- “附加视频”

必要的 Jellyfin/API 固有字段名可以保留英文，但不要把解释写成术语表演。

### 5. 不要把重复粘贴文本误判成用户真的运行了两次

本轮发现 ChatGPT 输入框 / Typeless / 浏览器插件链路会把大段终端文本重复插入。用户后来把原始终端内容保存成 txt 再上传，确认本地只执行过一次，但上一条聊天文本里整块结果被重复了。

用户怀疑和开启“绝对复制”插件有关；至少已经确认：

> **看到同一消息里整块终端输出重复，不得据此推导“用户又运行了一遍”。**

除非两段之间有真实不同的命令、时间戳或状态变化，否则按输入重复处理。

### 6. API Key 永远不要写入仓库或交接文档

本轮聊天里曾出现真实 Jellyfin API Key，用户表示会销毁换新。

下一模型不要复述旧 key，不要写进任何文件、issue、日志样例或回答。

---

## 三、环境、源目录与输出目录

Jellyfin：

```text
Version: 12.0.0
Server: http://127.0.0.1:8096
```

真实源媒体目前至少包括：

```text
D:\Bangumi\...
C:\bangumi\...
D:\Gekijouban\...
```

用户不希望重命名或移动原始收藏。新方案仍然是通过硬链接/必要复制建立一个独立整理层。

### C 盘新整理根目录已经明确

用户特别指定：

```text
C:\resource\video\anime
```

不要写成：

```text
C:\BangumiLink
C:\anime
```

也不要直接污染 C 盘根目录。

原因和 D 盘项目输出不放根目录一样。

### D 盘新一代整理库根目录暂未最终锁定

旧实验产物主要在：

```text
D:\Resource\BangumiLink\View\
D:\Resource\BangumiLink\View-v3\
D:\Resource\BangumiLink\Logs\
```

但当前已经决定“重新建一批新的硬链接整理库”，因此不要擅自假定新一代一定继续叫 `View-v4`。先在映射表基本完成后再确定最终 D 盘根目录。

### 硬链接不能跨卷

C 盘源文件不能硬链接到 D 盘目标。

所以 C 盘来源应在：

```text
C:\resource\video\anime
```

建立同卷硬链接；D 盘来源则建立在 D 盘整理根目录。Jellyfin 一个逻辑媒体库可以挂多个目录，因此最终“2025年04月新番”等逻辑库可以同时包含 C/D 两边对应路径。

---

## 四、截至目前已经完成的主要技术工作

下面很多不是下一步要继续扩展的方向，但必须知道，避免重走弯路。

### 1. 243 个 correction target NFO

早期为 243 个 TV Episode 写过最小同名 NFO，只包含 season / episode。

确认：

- Jellyfin 12 FullRefresh 可以读取这些 S/E；
- 但 NFO 不能可靠解除已经形成的 `LocalAlternateVersion`；
- 问题根因之一是路径解析在读取 NFO 之前就可能先得到错误 Episode key。

相关结构问题继续见 issue #4。

### 2. 路径解析 / LocalAlternateVersion 根因

已经确认祖先目录中类似：

```text
2026-01
2026-07
```

这样的数字-数字结构可能干扰 Jellyfin 的 episode parser，导致不同物理文件先被判成同一集，再建立本地多版本关系。

显式整理文件名：

```text
S02E09 - 原始字幕组文件名.mkv
```

能够稳定让 Jellyfin 按正确集号导入。

### 3. 完整硬链接 View 从 PowerShell 迁到 Python

PowerShell 版本曾出现长路径 regex 等错误，随后迁到 Python。

确认真实 TV scope 时曾发生过“676 → 634”口径争议。最终通过 Jellyfin root diagnostic 确认：

```text
11 个 tvshows root entries
D 盘生产 TV roots（9 个）: 634 个视频
排除 test:                2 个视频
排除 C:\bangumi 杂项 TV:  42 个视频
ALL tvshows:              678 个视频
```

所以 634 并不是“全 TV”，而是当时选中的 9 个 D 盘生产 root。

Python 完整 View v2 首次 Apply：

```text
Production roots:    9
Source files:        1227
Source videos:       634
Correction targets:  243
HARDLINK rows:       738
COPY rows:           489
Created rows:        741
Reused rows:         486
```

第二次 dry-run：

```text
Reusable rows: 1227
Rows to create: 0
Conflicts:      0
```

随后做了 View-v3，用于更好处理语言 sidecar、光之美少女子目录等问题。

View-v3 Apply：

```text
View root:          D:\Resource\BangumiLink\View-v3
Source files:       1227
Source videos:      634
Correction targets: 243
CORRECTION_SIDECAR: 321
CORRECTION_VIDEO:   243
PASSTHROUGH_FILE:   272
PASSTHROUGH_VIDEO:  391
HARDLINK rows:      738
COPY rows:          489
Created rows:       1227
```

随后 dry-run 证实 1227/1227 全部 reusable。

### 4. 分组媒体库已经自动创建过

用户不接受“所有动画揉进一个大媒体库”，仍要保留类似：

```text
2017年动画
2023年动画
2025年01月新番
2025年04月新番
2025年07月新番
2025年10月新番
2026年01月新番
2026年04月新番
2026年07月新番
```

因此已经写了：

```text
scripts/create_jellyfin_grouped_libraries.py
```

注意命名规则：1/4/7 月必须补前导 0，避免字典序把 10 月排到 1 月前面：

```text
01 / 04 / 07 / 10
```

目录本身可以仍叫 `2025年1月新番`，Jellyfin 库名显示为 `2025年01月新番`。

曾经建过一个模板库 `raw`，后来用户已经删除。不要再把问题归因于 raw 库重叠。

### 5. TVDB 被放到优先位置，但又暴露出元数据层问题

新分组库创建后，Series identity audit 一度显示：

```text
53 Series
46 同时有 TVDB ID + 主海报
7 完全没自动识别
```

最初失败的 7 部全部来自 2026 年以前、字幕组式 Series 文件夹：

1. 幼女战记
2. 偶像大师 灰姑娘女孩 U149
3. 前桥魔女
4. 克雷瓦提斯-魔兽之王与婴儿与尸之勇者-
5. 瑠璃的宝石
6. 藤本树 17-26
7. SPY×FAMILY Season 3

用户手工 Identify 后一度正确，但其中一部分后来又退化回文件夹名。2026 那批干净目录并没有发生同样退化；不要再泛化成“2026 也掉了元数据”。

正确身份曾从真实 Jellyfin 日志反查出来：

| 作品 | IMDb | TMDB | TVDB |
|---|---|---:|---:|
| 幼女战记 | `tt6455986` | `69346` | `315500` |
| 偶像大师 灰姑娘女孩 U149 | `tt26699386` | `216391` | `424278` |
| 前桥魔女 | `tt35351289` | `270602` | `454132` |
| Clevatess | `tt32991344` | `258348` | `451793` |
| 瑠璃的宝石 | `tt37113118` | `271649` | `454330` |
| 藤本树 17-26 | `tt38491451` | `299778` | `467641` |
| SPY×FAMILY | `tt13706018` | `120089` | `405920` |

### 6. TVDB Missing Episode Fetcher 已关闭

日志中发现 TheTVDB 的 `Missing Episode Fetcher` 会制造大量无文件虚拟 Season/Episode；删除/重扫媒体库期间还出现大量：

```text
SQLite Error 19: 'FOREIGN KEY constraint failed'
```

堆栈落在 TVDB missing episode 相关逻辑。

已经写：

```text
scripts/disable_jellyfin_missing_episode_fetcher.py
```

并且用户最终重新读取确认 9 个整理后的 TV 库都是：

```text
To update:       0
Already disabled: 9
```

即已经关闭。

注意：这个脚本只是禁用以后继续制造缺失集，不会自动删除数据库中历史遗留的虚拟 Season/Episode。

### 7. 给 7 部写过最小 `tvshow.nfo`

已经写：

```text
scripts/write_jellyfin_series_identity_nfos.py
```

在 View-v3 的 7 个 Series 目录中创建最小 `tvshow.nfo`，包含干净标题和三套 provider IDs；不写简介、分集、图片、displayorder。

用户真实 Apply：

```text
Targets:   7
Create:    7
Conflicts: 0
Created 7 tvshow.nfo file(s). Verified 7 target(s) as REUSE.
```

但这一步只解决 Series identity，不等于 Episode metadata 已经恢复。

### 8. 7 部三层检查已经把问题拆清

脚本：

```text
scripts/inspect_jellyfin_seven_series.py
```

真实结果摘要：

#### 幼女战记

```text
Series IDs / overview / image: 正常
seasons=3 indexes=0,1,2
episodes=42
episode-tvdb=42
overview=23
image=13
```

大量额外 Episode 是历史 `Missing Episode Fetcher` 虚拟条目；真实 SP 等也混在里面。

#### U149

```text
Series 正常
seasons=3 indexes=0,1,?
episodes=16
numbered=15
seasoned=15
episode-tvdb=15
```

OVA 形成未知季/无编号条目，需要以后按真实身份处理。

#### 前桥魔女

```text
Series ID 已恢复
Series overview 缺失
seasons=1 indexes=?
episodes=12
numbered=12
seasoned=0
episode-tvdb=0
overview=12
image=12
local-name=12
```

即 E01-E12 有集号，但 Season 为空，所以进入“未知季”，Episode TVDB ID 也没有。

#### Clevatess

```text
Series 正常
episodes=29
episode-tvdb=29
```

但里面有大量虚拟条目和附加视频误识别。尤其 Menu / PV / NCOP / NCED / 特典映像不应该被当普通正片 Episode。

#### 瑠璃的宝石

```text
Series ID 已恢复
Series overview 缺失
seasons=1 indexes=?
episodes=13
numbered=13
seasoned=0
episode-tvdb=0
overview=0
image=13
```

UI 表现为“未知季”。

#### 藤本树 17-26

```text
Series ID 已恢复
Season 1 正常
episodes=8
numbered=8
seasoned=8
episode-tvdb=0
overview=0
local-name=8
```

Series 认对，但 Episode 标题仍是 `S01E01 - [SweetSub...]` 文件名样式。

#### SPY×FAMILY

```text
Series ID 已恢复
Season 3 正常
episodes=13
numbered=13
seasoned=13
episode-tvdb=0
overview=7
local-name=13
```

也是 Series/Season 对了，Episode metadata 没完整恢复。

---

## 五、当前值得记录的 Jellyfin bug / issue 候选

用户已经明确：不要把以前讨论过的所有 issue 又翻一遍。这里记录的是**最近新暴露、和本轮元数据刷新机制直接相关**的候选。

### 候选 A：安全刷新不能纠正已有的错误 Episode Name

Jellyfin 合并远端 metadata 时，普通刷新 / `replaceAllMetadata=false` 对 `Name` 的行为是：

```text
如果当前 Name 非空，就保留当前 Name；
只有 replaceData=true 或当前 Name 为空时才用 provider Name。
```

因此初次 parser 已经把文件名解析成：

```text
S01E01 - [SweetSub...] Fujimoto Tatsuki...
```

以后即使 provider 能得到正确标题，普通安全刷新也不会覆盖这个非空错误 Name。

搜索现有 issue 时找到 Jellyfin #14080：它报告的是相同底层合并思想导致 provider 无法纠正已有 `ParentIndexNumber`，说明“已有非空字段阻止远端 provider 修正”并非完全未知。但截至当前搜索，没有找到一个直接对应：

> **Episode 文件名 fallback Name 已非空，所以普通元数据刷新永远不能纠正标题。**

这个具体表现很可能值得新的 issue。

最佳后续做法：不要用当前已经反复修改过的脏库提交。等新硬链接库第一次扫描时，如果可以干净复现“provider 返回正确 Episode metadata，但 Name 因非空不替换”，再做最小复现并报。

### 候选 B：TheTVDB Missing Episode Fetcher 与删除库竞争导致外键失败

2026-08-15 日志里出现大量：

```text
SQLite Error 19: 'FOREIGN KEY constraint failed'
```

背景是 Jellyfin 删除 Folder/Season/Episode 时，TVDB missing episode 逻辑又响应 ItemRemoved 并尝试创建无文件虚拟 Season/Episode。

这个现象和已有 Missing Episode Fetcher 的异常行为有关，但“删除父项同时插件新建子项导致 FK 失败”是否已有完全一致 issue 尚未彻底确认。

当前主线不需要继续调查它，因为 Missing Episode Fetcher 已经禁用；把证据保留即可。

### 候选 C：`ReplaceAllMetadata=true` 的字段清空不对称

Medalist S02E01 实验中曾出现：

- FullRefresh + replaceAllMetadata=true 被接受；
- 原有 Overview 后来消失；
- Name `Medalist` 没被替换；
- provider IDs 仍在；
- 日志默认级别看不到完整 provider 返回。

后续源码分析显示某些字段对空 provider 结果的处理并不完全对称。这个仍可作为候选，但当前优先级低于新库重建。

---

## 六、为什么现在决定彻底重建新的硬链接整理库

过去几天已经证明，继续修现有数据库会出现非常烦人的连锁：

```text
Series 认对了
→ Season 可能未知
→ Episode 编号可能有但 provider ID 没有
→ Overview 可能有一半
→ 图片可能还在
→ Name 可能仍是文件名
→ 刷新又受 replaceAllMetadata 合并语义限制
→ Missing Episode Fetcher 还曾制造虚拟条目
```

用户已经明确厌倦这种“刷新一次又冒出一个新层问题”的做法。

因此不要继续为：

- 前桥魔女未知季
- 瑠璃未知季
- 藤本树 Episode 标题
- SPY×FAMILY Episode 标题

分别再写一堆临时修补脚本。

**View-v3 应视为非常有价值的实验阶段产物，但不是最终要继续无限打补丁的生产结构。**

---

## 七、当前最新输入：720 个真实视频路径清单

用户已经从本机真实文件系统导出：

```text
anime-video-files.txt
```

共约 720 个视频路径，来源覆盖：

```text
D:\Bangumi
C:\bangumi
D:\Gekijouban
```

这份文件是下一阶段最重要的事实来源。

如果下一对话无法直接访问本轮上传文件，可以让用户重新上传；也可以让用户用下面的只读命令重新生成：

```powershell
$roots = @(
    'D:\Bangumi',
    'C:\bangumi',
    'D:\Gekijouban'
)

$videoExt = @('.mkv', '.mp4', '.m4v', '.avi', '.ts', '.webm')

Get-ChildItem $roots -Recurse -File |
    Where-Object { $videoExt -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName } |
    Set-Content -Encoding UTF8 .\anime-video-files.txt
```

不要把完整私人文件清单直接提交到公开仓库；可以提交抽象后的映射规则/手工判定表，但注意用户隐私边界。

---

## 八、720 文件人工归类已经确认的一些原则和例子

### 1. DIY 放 `2022年动画`

用户明确纠正：

```text
Do It Yourself!! -> 2022年动画
```

不要放：

```text
2022年10月新番
```

清单里 C/D 两边都有完整 DIY 正篇来源：

```text
C:\bangumi\[SweetSub&VCB-Studio] Do It Yourself!! ...
D:\Bangumi\2022\[SweetSub] Do It Yourself!! ...
```

C 盘版本还带 NCOP/NCED。

这应视为同一作品的两个完整来源/版本，不能在 Jellyfin 里误建成两个 Series。

### 2. BDRip 目录中也会有大量附加视频

用户特别提醒：TV 和剧场版很多附加视频来自 BD，整个文件夹也会写 BDRip。

因此：

> **看到 `BDRip` 绝不能推导“这就是正片 Episode”。**

必须看实际文件名和子目录。

例如 Clevatess 目录里除了 12 集正篇，还有：

- Menu
- NCOP / NCED
- PV
- Tokuten / 特典映像

这些应和正篇区别开。

### 3. 附加视频与正式特别篇必须人工区分

一般：

```text
NCOP / NCED / Menu / CM / PV / Information
```

优先视为附加内容，不作为普通 Episode。

但：

```text
SP / OVA / 特典动画
```

不能一刀切。它可能是数据库正式收录的 Special，也可能只是 BD 附件。必须结合文件名、内容语义和 TVDB/TMDB 条目判断。

### 4. 已确认的典型特殊项目

- 2017 《幼女战记》目录里 `[00][SP]` 到 `[12][SP]` 是一套真正的迷你动画特别篇，不应简单扔到 extras。
- U149 `[OVA]` 是真正动画特别篇，但精确 TVDB special 编号仍应在最终映射前再核。
- `Chainsaw Man - The Compilation - 01/02` 更像 TV Series 的两篇总集特别篇，不应当作两部普通电影。
- `Kaguya-sama ... Otona e no Kaidan - 01/02` 是《辉夜大小姐》的正式特别篇，应该归 TV Series Specials。
- `HELLO WORLD` 目录里的 `ANOTHER WORLD - 01/02/03` 是独立的三话动画系列，不是电影花絮。
- 《剧场版幼女战记》的 `CM`、`Main PV`、`Menu`、`Information`、`Theater Preview` 等明确是电影附加内容。
- `Chou Kaguya-hime` 若同时有 `[Movie]` + `[MV]`，正片和 MV 要分开，MV 属电影附加内容。

### 5. 有些连续编号要转换为真实 Season/Episode

已经观察到：

- `100女友` 2025 目录用 `S01E13-E24` 连续编号，但整理时应对应第二季 E01-E12；2026 后续连续编号则对应第三季。
- `SPY×FAMILY` 某些文件用整部作品累计话数如 38、39、40……，整理时应转为 S03E01、S03E02……
- Frieren 第二季文件可能用全局第 29–38 话，应转为第二季 E01–E10。
- Medalist 第二季同时存在全局 14–18 和明确 `S2 02–09` 两套命名，重叠部分可能是不同字幕组/真实多版本，不能自动删除。

### 6. v2 与多字幕组版本

- 同字幕组同一集 `08` / `08v2`：通常 `v2` 是修正版，映射表应明确优先级；原文件不删除。
- 不同字幕组同一集：这是合法的多版本，不要当重复垃圾删掉。

最终映射表需要有 `version_group` / `preferred` 或等价字段，让执行脚本知道这是同一集的多个版本，而不是目录冲突。

---

## 九、下一步具体应该做什么

**不要先写执行脚本。**

下一步应该继续把 `anime-video-files.txt` 压成一张真正的事实表。

建议字段至少：

```text
source_path
source_drive
work_title
library_group
media_kind          # tv_episode / tv_special / movie / extra / ova / etc.
season
episode
provider_series_id  # 可选，TVDB/TMDB
provider_episode_id # 仅必要时
version_group
preferred_version
target_drive
target_relative_path
target_filename
notes
confidence
```

工作顺序：

1. 先按作品聚合 720 个文件；
2. 对每个作品人工读文件名和目录；
3. 正片 Season/Episode 先判；
4. 再判 SP/OVA/特典动画；
5. 再判 NCOP/NCED/PV/CM/Menu/Information 等附加视频；
6. 再处理电影、电影附加内容；
7. 最后处理 v2、多字幕组多版本；
8. 只有文件名和上下文真的不足以判断时，再查 TVDB/TMDB；
9. 判定表审阅完成后，才写一个很笨的执行脚本：逐行创建硬链接，不自己猜。

### 执行脚本应满足

- 默认 dry-run；
- 原始文件绝不移动、不改名、不删除；
- 同盘视频用 hardlink；
- 跨盘不做 hardlink；C 源必须落在 C 盘整理根；
- sidecar（字幕/NFO 等）根据最终规则复制或硬链接，但不要让脚本自己猜身份；
- 冲突立即停止；
- manifest 明确记录 source -> destination；
- 可重复运行；
- 不要为此重建一套复杂“自动识别字幕组命名”的框架。

---

## 十、issue / 文档维护

当前至少不要忘：

- #4 `NFO 写入后仅部分识别问题得到修正`：结构历史主线，open；
- #5 `Episode 季集号正确后仍保留错误标题 / 元数据不完整`：metadata 主线，open；
- #8 `PowerShell 同一进程中 Add-Type 缓存...`：旧 PowerShell 技术债，open。

但是当前主线已经从“继续修现有 View-v3”转向“重新做人/LLM 判定表 + 新硬链接库”。应该在适当时机把这个方向变化回填 issue/history，而不是让 issue 永远停留在 8 月 14 日的计划。

新的候选 bug（安全刷新 Name、TVDB missing episode FK race）先写调查记录/候选说明，不要为了“多报 issue”而立即提交上游；等新库能干净复现再报更有价值。

---

## 十一、最后的提醒

这个项目已经因为“再补一个字段、再刷新一次、再写一个脚本”走了很多弯路。

下一阶段最重要的变化是：

> **先把收藏内容本身理解正确，再让 Jellyfin 来读；不是继续依赖 Jellyfin 的旧数据库状态告诉我们文件是什么。**

Jellyfin 当前识别只能当辅助证据，不能当事实源。它已经真实出现过：

- Menu 被识别成 Episode；
- NCOP / 特典映像被误当正片；
- 不同 Episode 被做成 LocalAlternateVersion；
- 正确 Series 下 Episode metadata 仍残缺；
- 无文件虚拟 Episode 大量出现。

事实源优先级应该是：

```text
真实源文件名
> 目录上下文
> 字幕组命名规律
> TVDB/TMDB 正式条目
> Jellyfin 当前数据库（仅辅助）
```

把这条守住，下一阶段会比过去几百次小修补简单得多。
