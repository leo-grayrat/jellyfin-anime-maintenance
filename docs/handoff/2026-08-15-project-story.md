# 2026-08-15 项目探索历程与协作背景：从“修 Jellyfin”到“先理解收藏本身”

这份文档不是命令清单，也不是脚本说明。

它记录的是：这个项目为什么从一个看起来很简单的动画元数据问题，一路走到 NFO、LocalAlternateVersion、硬链接 View、TVDB、元数据刷新、数据库 race，最后又决定把主线彻底改成“先逐项理解真实文件，再重建整理库”。

下一位接手的模型应同时阅读：

```text
docs/handoff/2026-08-15-next-conversation.md
```

技术交接回答“现在具体有什么、下一步做什么”；本文回答“为什么走到这里、哪些错误不要再重演”。

如果需要更完整的前半段细节，还可以继续读：

```text
docs/handoff/2026-08-14-project-story.md
```

---

## 一、这个项目从来不是为了把收藏改造成 Jellyfin 喜欢的样子

最开始的问题很生活化：用户有一套长期保存的动画收藏，目录按年份、季度、作品组织，文件名保留字幕组发布时的原始信息。

这些名字里会有：

- 字幕组；
- 版本号；
- 分辨率和编码；
- 全局话数；
- 分季话数；
- BDRip / WebRip；
- SP / OVA；
- NCOP / NCED；
- PV / CM；
- 特典映像；
- v2 修正版。

这些不是“需要清洗掉的脏名字”，而是收藏本身的信息。

所以用户从一开始就不接受最简单的答案：

```text
全部重命名成 S01E01.mkv
```

不是不知道这样 Jellyfin 最开心，而是不愿为了播放器破坏原收藏。

这个项目的价值取向一直是：

> **让 Jellyfin 适应收藏，而不是让收藏服从 Jellyfin。**

这个原则在后面经历无数技术弯路之后反而越来越重要。

---

## 二、我们最早以为：只要补一点 NFO 就够了

最初的错误看起来只是季集号识别问题：

- 第二季被放到第一季；
- 不同集被当成同一集；
- 季度目录里的 `2026-01`、`2026-07` 似乎会被 Jellyfin 读错；
- 某些字幕组只写 `[09]`，Jellyfin 猜错了 Season/Episode。

所以最自然的方案就是最小 NFO：

```xml
<episodedetails>
  <season>2</season>
  <episode>9</episode>
</episodedetails>
```

它看起来非常优雅：不改视频、不改文件名、只给播放器一个提示。

项目因此建立了 correction rules，最终覆盖了 243 个 Episode。

但第一次大规模结果就说明事情没那么简单。某些集号数字确实被改了，可 UI 里仍然有错误关系；有些条目甚至根本找不到。

继续查下去才发现，问题不只是“数字字段错”。

---

## 三、LocalAlternateVersion 把问题从“元数据”变成了“身份关系”

后来发现很多“消失的 Episode”其实还在数据库里，只是被 Jellyfin 当成了另一个 Episode 的本地多版本 child。

也就是说，事情不是：

```text
一个文件 → season/episode 猜错
```

而是：

```text
多个真实不同的物理 Episode
→ Jellyfin 很早就认为它们是同一集的不同版本
→ 只显示一个 owner
→ 其他文件藏成 LocalAlternateVersion
```

这解释了为什么后来 NFO 即使把 child 的 Season/Episode 改正确，UI 仍然没有完全恢复。

我们一度怀疑这只是旧数据库脏关系，于是做过 remove/re-add、SQLite 只读诊断等实验。

结果更麻烦：同一个原始文件重新加入后，Jellyfin 会重新制造同样的错误关系。

因此项目得到了一个非常重要的结论：

> **直接修数据库关系不是根治。必须改变 Jellyfin 第一次看到文件时的输入。**

---

## 四、真正的根因之一：Jellyfin 居然会从完整路径里解析 Episode

继续缩小实验后发现，把同一个文件用显式名字：

```text
S02E09 - 原字幕组文件名.mkv
```

重新加入，识别会明显稳定。

进一步查 Jellyfin 路径解析逻辑，才确认祖先目录里的：

```text
2026-01
2026-04
2026-07
```

这种数字-数字结构可能提前参与 Episode 解析。

这对用户来说很反直觉，因为季度目录只是收藏管理结构，根本不是剧集编号。

但 Jellyfin 会看完整路径。

这件事逼出了第一代真正有效的工程折中：**硬链接整理 View**。

原始收藏不动，在同一磁盘创建硬链接，然后只给 Jellyfin 看一套显式 `SxxEyy` 的名字。

这是一个很重要的阶段，因为它证明“整理层”方向本身是对的。

---

## 五、PowerShell 把很多本来不该复杂的事情搞得更复杂

早期工具大量使用 PowerShell。

这一路踩过：

- UTF-8 / Windows PowerShell 5.1；
- `[02]` 一类路径被当通配符；
- regex 转义；
- MAX_PATH；
- PathRoot；
- 中文路径；
- 长路径和 provider 行为。

最终复杂 View 构建迁到 Python 后明显稳定。

这个经历后来变成用户非常明确的一条要求：

> **复杂逻辑优先 Python，不要因为“这是 Windows”就本能写 PowerShell。**

而且用户后来进一步指出，AI 很容易为了“工程感”在云端做大量假的 Windows 验证、反复算 hash、Git blob SHA。这个项目没有多人并发，也没有真实 Jellyfin 环境，这些动作很多只是仪式。

所以现在的工程纪律不再是“越多检查越专业”，而是：

> **只做能降低真实风险的检查。真实 Jellyfin 行为必须回到用户本机验证。**

---

## 六、View-v2 / View-v3 一度让我们以为主体问题已经结束

完整 Python View 最终成功覆盖 9 个 D 盘生产 TV roots：

```text
Source videos: 634
Source files: 1227
Correction targets: 243
```

View-v3 又修正了 sidecar、光之美少女等结构问题。

第二次 dry-run 能完整复用，说明文件层生成本身已经稳定。

这一阶段有一个很重要的口径争议：曾经出现过 676、634 等数字。

最后确认：

```text
634 = 当时选中的 9 个 D 盘生产 TV roots
42  = C:\bangumi 杂项 TV
2   = Jellyfin-Repro 测试文件
678 = 全部 tvshows roots
```

这个争议也提醒项目：不要从“当前脚本 scope”偷偷推成“整个动画库”。

当时用户还坚持一个重要需求：不能把所有动画揉进一个巨大的媒体库。

因此后面又做了分组媒体库：

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

这一点以后也要保留。

---

## 七、文件结构修好了，元数据 provider 又开了第二个坑

View-v3 解决了大量“Jellyfin 不知道这是第几集”的问题，但之后开始出现另一层：

> **它知道这是 S02E06，却还是拿不到正确标题、简介、图片。**

一开始怀疑 NFO、语言代码、刷新方式。

后来通过 debug 日志确认：

```text
TmdbEpisodeProvider returned no metadata
```

再去看 TMDB 数据，才发现很多动画的数据库模型与用户本地季结构根本不同。

例如：

- Frieren 第二季在 TMDB 上作为另一部 Series；
- Oshi no Ko 的本地 S2/S3 与 TMDB 原 Series 的季结构不一致；
- Fate/strange Fake 的特殊篇结构也有差别。

这件事很重要，因为它把一个看起来像 Jellyfin bug 的现象推翻了：

> provider 返回空，不一定是 Jellyfin 抓取坏了，也可能是你拿着错误的数据库坐标去查询。

后来安装 TVDB 后，发现 TVDB 对这些动画的季结构明显更贴近用户期望。

于是项目主 provider 又逐渐转向 TVDB。

---

## 八、TVDB 解决了数据库模型，却又把 Series identity 问题暴露出来

新分组库建立后，53 个 Series 里最初有 7 个没自动识别：

1. 幼女战记
2. 偶像大师 灰姑娘女孩 U149
3. 前桥魔女
4. 克雷瓦提斯
5. 瑠璃的宝石
6. 藤本树 17-26
7. SPY×FAMILY Season 3

这些目录有一个共同特征：很多仍然是字幕组发布式的长 Series 文件夹名。

用户手工 Identify 后一度恢复，但后来其中一些又退回文件夹名。

这让用户非常不满，因为这意味着即使你“修好了”，下一次扫描/刷新又可能改变状态。

于是我们写了 Series identity audit，用 CSV 去追踪 SeriesId、TVDB/TMDB/IMDb、Overview、Episode 状态等。

重要发现：发生退化时，SeriesId 没变。

所以不是 Jellyfin 删除后新建了一个 Series，而是在**同一个 Series item 上丢/覆盖了身份或文字元数据**。

---

## 九、Missing Episode Fetcher 让“元数据刷新”第一次直接撞到数据库完整性

用户上传了一天的 Jellyfin 日志。

里面出现了几百次：

```text
SQLite Error 19: FOREIGN KEY constraint failed
```

堆栈指向：

```text
Jellyfin.Plugin.Tvdb.Providers.TvdbMissingEpisodeProvider
```

尤其在删除媒体库、扫描、刷新期间，父 Series/Season 正在被移除，插件又在创建虚拟 missing Season/Episode。

这不是 UI 上“不好看”这么简单，而是实际数据库写入 race。

于是我们专门写脚本关闭 9 个分组库里的 `Missing Episode Fetcher`，最终本机确认：

```text
Already disabled: 9
```

但旧虚拟项不会自动消失。

七部作品的详细检查后来证实：幼女战记、U149、Clevatess 下面已经积累了一堆没有真实 Path 的虚拟 Episode。

这也让用户对“再点一次刷新试试看”越来越失去耐心。

---

## 十、我们最后又尝试了一次最小 Series NFO，但它只解决了一层

为了稳定那 7 个 Series identity，我们做了很克制的 `tvshow.nfo`：

```xml
<tvshow>
  <title>干净标题</title>
  <uniqueid type="tvdb">...</uniqueid>
  <uniqueid type="tmdb">...</uniqueid>
  <uniqueid type="imdb">...</uniqueid>
</tvshow>
```

不写简介、不写 year、不写 Season/Episode、不写图片。

本机成功写入 7 个 View-v3 Series。

接下来 Jellyfin 的表现非常具有代表性：

- Series 标题和三个外部链接恢复了；
- 海报也可能出现；
- 但简介可能没有；
- Season 可能变成“未知季”；
- Episode 标题仍然是字幕组文件名；
- Episode TVDB ID 仍然为空；
- 图片和 Overview 的完整性每部还不一样。

也就是说：

> **Series identity 修好，不等于 Season / Episode 元数据一起修好。**

这正是用户最讨厌手动刷新的地方：UI 看上去“好像成功了”，点进去才发现下面又是另一坨状态。

---

## 十一、七层审计把“刷新屎山”拆开了

为了不再靠 UI 猜，我们写了一个只读脚本逐层查看 7 部作品：

```text
Series
Season
Episode
```

结果非常清楚。

### 前桥魔女

12 集 EpisodeNumber 都有，但 SeasonNumber 全空；因此全部落到“未知季”。TVDB ID 也全空，标题仍像本地文件名。

### 瑠璃的宝石

13 集 EpisodeNumber 有，SeasonNumber 全空，TVDB ID 全空，Overview 全空；这正对应 UI 的“未知季”。

### 藤本树 17-26

S01E01–08 数字都正确，Season 1 也正常，但 Episode TVDB ID 全空，标题仍是文件名。

### SPY×FAMILY

S03E01–13 数字正确，Season 3 正常，但 Episode TVDB ID 全空，标题仍是文件名。

这说明“季号错误”和“provider 没真正覆盖分集元数据”是两种不同问题。

更麻烦的是 Jellyfin 的安全刷新合并逻辑：已有非空 `Name` 时，`ReplaceAllMetadata=false` 不会让远端标题覆盖它。

于是出现一个很荒谬的局面：

```text
安全刷新
→ 不破坏现有字段
→ 但错误的文件名标题也不改

强制 ReplaceAll
→ 能覆盖标题
→ 又可能把 provider 没返回的字段清掉
```

用户说自己已经厌倦这种元数据刷新屎山，这个判断完全来自真实经历，不是情绪化夸张。

---

## 十二、这里还出现了一个新的上游 issue 候选

用户特别要求区分：最近问“有没有新的 Jellyfin issue”时，并不是让我们把过去所有 issue 再复述一遍，而是专门问刚发现的这条合并行为。

现象是：

> Episode 初始 Name 来自本地文件名；远端 provider 后来已经有正确标题；但普通刷新由于当前 Name 非空，不覆盖它。

我们专门搜索现有 issue，没有找到一个完全对应“Episode 文件名标题无法被普通元数据刷新纠正”的报告。

但找到 #14080 作为非常近的先例：provider 返回正确 ParentIndexNumber，也因为 `replaceData=false` 被旧非空值挡住。

所以这里不是完全全新的底层思想，但**“文件名标题永远卡住”的具体表现仍很值得在新库里做干净复现后提交。**

同时还有另一个早先候选：`ReplaceAllMetadata=true` 时 provider 不完整可能清掉已有 Overview，但 Name 又有特殊保护。

这两个问题不要混在一起。

---

## 十三、真正让路线改变的，不是某一个 bug，而是用户意识到我们一直在“补残局”

到这个阶段，用户提出了一个非常关键的批评：

> 我们一直在想怎么用脚本把坏状态格式化、补 NFO、刷新、再补另一个字段。但根本问题其实是：这些文件是什么，人和大语言模型看名字就看得懂。为什么不先把它们理清楚？

这是整个项目第二个最大的转折。

字幕组文件名并不是随机字符串。

看到：

```text
NCOP
NCED
OVA
SP
PV
CM
Menu
特典映像
特典动画
v2
```

人当然知道这些不是同一种东西。

看到：

```text
S01E13–24
```

再结合“这是 100 女友第二季”，就知道它其实需要转换成 S02E01–12。

看到：

```text
Spy x Family - 38
```

再结合第三季上下文，也能判断为 S03E01。

以前我们不断尝试让一个通用脚本自己“悟出”这些语义，最后自然会变成正则补丁堆。

用户因此明确提出：

> **先由人/大语言模型逐项读真实文件名，形成事实表；脚本只负责机械执行。**

这不是退回手工劳动，而是把“语义判断”和“文件操作”正确分层。

---

## 十四、新阶段的原始材料第一次真正覆盖了 TV + 杂项 + 剧场版

用户导出了三个源根下所有视频：

```text
D:\Bangumi
C:\bangumi
D:\Gekijouban
```

得到：

```text
anime-video-files.txt
```

共 720 个视频路径。

这份清单比 Jellyfin 数据库更接近事实，因为 Jellyfin 已经证明会把：

- Menu；
- NCOP / NCED；
- PV；
- 特典映像；
- 剧场版宣传片；

错误当作普通 Episode 或电影。

从这个文件开始，项目第一次准备把：

- 原来 9 个 D 盘 TV 库；
- C 盘“杂项动画”；
- D 盘剧场版；

放到同一套“真实文件语义整理”里处理。

---

## 十五、C 盘“杂项动画”其实根本不应该一直是杂项

用户特别提醒，C 盘那几部原来只是之前被遗漏，并不是真的属于一个长期“杂项库”。

现在已经明确：

```text
Do It Yourself!!                         → 2022年动画
Sousei no Aquarion - Myth of Emotions   → 2025年01月新番
Mobile Suit Gundam GQuuuuuuX            → 2025年04月新番
```

尤其 DIY，用户专门纠正：

> **放 `2022年动画`，不要放 `2022年10月新番`。**

而且 C/D 两边各有一套 DIY，说明新整理还必须面对“整套重复来源”和“同一集不同版本”，而不是简单每个文件都变成独立 Episode。

C 盘整理层的位置也已明确：

```text
C:\resource\video\anime
```

用户不希望往 C 盘根目录直接扔项目目录，原因和 D 盘一样。

---

## 十六、BDRip 这三个字差点让我们再犯一次“把目录当语义”的错误

用户特别提醒：

> 有些 TV 和剧场版目录里有很多附加视频，它文件夹也会写 BDRip。

这句话非常重要。

`BDRip` 只说明来源，不说明这个文件是正片。

一个 BDRip 目录里完全可能同时有：

```text
01–12 正篇
NCOP
NCED
PV
CM
Menu
Tokuten
特典动画
Information
```

所以新映射不能再写成：

```text
在 BDRip 文件夹里 → Episode
```

必须逐项理解文件名。

但反过来也不能说：

```text
BD 附送 → 一律 extras
```

因为有些 BD 附送动画本身是数据库正式收录的 Special。

这正是“需要人/模型语义判断”的最好例子。

---

## 十七、几个剧场版目录已经证明“物理文件夹分类”也会骗人

旧 `D:\Gekijouban` 里面不全是电影。

已经查清几个典型：

### 剧场版幼女战记

电影正片旁边有 CM、PV、Menu、Information、Theater Preview 等。旧 Jellyfin 会把这些附加视频也当成同一部电影。

### Chainsaw Man - The Compilation - 01/02

看起来在剧场版目录，但其实应归《链锯人》TV 的正式特别篇/总集篇。

### Kaguya-sama ... Otona e no Kaidan - 01/02

也是 TV 正式特别篇，不是两部独立电影。

### HELLO WORLD 目录下的 ANOTHER WORLD

三话 `ANOTHER WORLD` 是独立短篇动画系列，不是电影花絮。

### Chou Kaguya-hime

`Movie` 是正片，`MV` 是附加 MV。

这个阶段又一次验证了同一个原则：

> **文件夹所在位置只能提供上下文，不能直接当最终身份。**

---

## 十八、用户对协作流程的几次强烈纠正，也属于项目知识

这一天不仅技术路线改变，协作方式也被用户反复纠正。

### 1. 不要已经同意了还反复确认

有一次用户已经同意 7 部 Series NFO 方案，模型又写设计文档、又请确认、又准备下一步。

用户明确指出：这会让工作变成“审批套审批”。

以后：已经批准的方向直接执行，设计文档只是记录，不是新的审批点。

### 2. 不要在云端做戏剧化验证

模型一度又开始克隆仓库、模拟测试、算 hash。

用户非常直接地指出：你根本没有我的 Jellyfin 环境，也没有别人同时改代码，天天算 hash 没意义。

以后不要用“工程严谨”掩盖没有真实价值的动作。

### 3. 不要把输入重复当成用户执行重复

聊天里曾多次出现整块终端输出重复。

模型据此推断用户做了“dry-run → apply → 又 dry-run”。

用户非常确定自己没有这样操作，后来把 raw 终端内容保存成 txt 上传，确认本地只有一份。

继续排查后，用户发现 Typeless / ChatGPT 输入框有时会出现“一份正常换行 + 一份无换行”的重复，很可能和刚打开的“绝对复制”插件有关。

所以以后看到大段完全重复文本，先当输入链路问题，不能拿它构造操作历史。

这些事情不是和技术无关的插曲。

这个项目本来就高度依赖真实环境和长对话，如果模型在流程上不断制造假确认、假验证、假时间线，技术判断也会越来越不可信。

---

## 十九、现在的项目哲学已经和最开始很不一样，但核心价值没变

最开始我们想：

> 尽量少动，只给坏 Episode 写 NFO。

后来发现 Jellyfin 的路径解析、LocalAlternateVersion、provider 模型、刷新合并、虚拟 missing episodes 都会让局部修补互相影响。

现在用户甚至明确说：

> 不要求最小改动了，直接建一批新的硬链接库比较好。

这看起来像从“克制”变成“重做”，其实核心原则完全没变：

- 原始收藏仍然不动；
- 原始字幕组文件仍然保留；
- 新整理层可撤销、可重建；
- 不直接改 Jellyfin SQLite；
- 不让播放器反向破坏源文件。

变化的只是我们终于承认：

> **为了得到长期稳定结果，整理层可以一次做完整，不必把“最小改动”误解成“永远只修一个字段”。**

---

## 二十、下一阶段最重要的事情不是写脚本，而是把事实表做出来

下一位模型接手后，真正应该做的是阅读 `anime-video-files.txt` 的 720 条路径，逐项判断：

- 作品是谁；
- 属于哪个逻辑媒体库；
- 是正篇、特别篇、OVA、电影还是附加视频；
- Season / Episode 应该是什么；
- 全局话数是否要转换；
- 是否是 v2；
- 是否和另一字幕组构成同一集的多版本；
- 是否是整套重复来源；
- 目标目录和目标文件名应该怎样写。

真正不确定的少量项目，再去查 TVDB/TMDB。

然后把这些判断写成一张能审阅的 manifest。

**只有事实表稳定之后，才写脚本。**

那个脚本应该很笨：

```text
读 manifest
检查源文件
创建目录
创建同卷 hardlink
复制必要 sidecar
冲突就停
```

它不负责“理解动画”。

---

## 二十一、这一路最大的教训

如果只从代码看，这个项目似乎绕了很多路。

但每条弯路都逼出了一个更准确的边界：

- NFO 证明“数字修正”不等于“身份关系修正”；
- LocalAlternateVersion 证明数据库关系可能早于元数据形成；
- remove/re-add 证明错误不是纯历史残留；
- 路径实验证明季度目录本身会干扰 Episode parser；
- hardlink View 证明独立整理层方向可行；
- TMDB mismatch 证明 provider 返回空不等于 Jellyfin bug；
- TVDB 证明数据库模型选择很重要；
- Missing Episode Fetcher 证明自动“补全”功能也可能污染库；
- Series NFO 证明“作品认出来”不等于“Season/Episode 都正常”；
- 安全刷新证明“不破坏字段”也可能意味着“永远不纠正错误字段”；
- 最后的 720 文件清单则让我们重新看见：真正的事实一直在原文件名里。

所以这个项目现在最应该避免的，不是某一个具体 bug，而是一种工作冲动：

> **一看到异常就马上再写一个脚本、再点一次刷新、再补一个字段。**

下一阶段应该慢在“判断事实”这一步，快在“执行已经确认的事实”这一步。

这才是这次交接真正需要保留下来的东西。
