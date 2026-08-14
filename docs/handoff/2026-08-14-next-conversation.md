# 2026-08-14 下一对话交接提示词

下面整段可以直接交给下一次 ChatGPT 对话继续工作。

---

你现在接手 GitHub 仓库：

```text
https://github.com/leo-grayrat/jellyfin-anime-maintenance
```

请继续维护我的 Windows Jellyfin 动画库。开始前先检查仓库当前 `main`、工作分支 `feat/tv-audit-export`、README、相关 history 文档、open issues 和 PR，不要只根据这份交接文字假定仓库状态没有变化。

## 一、工作方式：不要再忘记 issue

这是一个明确要求。

以后遇到新的、值得持续追踪的问题时：

1. 先搜索现有 issue；
2. 已有对应 issue，就把新的证据、实验、失败、结论持续回填；
3. 没有对应 issue，就创建 issue 后再继续较大的调查/修复；
4. 修复代码/文档要在对应分支推进，PR 中写 `Closes #N` 或明确关联 issue；
5. 只有真实验证完成并合入后才关闭 issue；
6. 不要让 issue 变成每条命令的流水账，但关键根因、失败实验、边界变化和最终结论必须进去。

当前 issue 状态：

- **#4 `NFO 写入后仅部分识别问题得到修正`**：结构问题主线，仍 open。已经补写了从 NFO、错误 LocalAlternateVersion、路径解析到 canonical view 的完整阶段更新。不要关闭，直到完整 TV canonical view 真正覆盖全库并切换验证完成。
- **#5 `Episode 季集号正确后仍保留错误标题 / 元数据不完整`**：当前 metadata 主线，open。Medalist / Fate/strange Fake / 100 女友第三期等都在这里继续追。
- **#6 `建立 TV 动画统一审计导出与结构/元数据问题账本`**：已通过 PR #7 合入 main 并自动关闭。不要重复实现这套 audit。
- **#8 `PowerShell 同一进程中 Add-Type 缓存会继续使用旧版 TV audit native helper`**：open。当前有规避方法，但还没有做永久类型版本化修复。

PR #7 `feat: 建立 TV 动画统一审计与问题账本` 已在 2026-08-14 squash merge 到 `main`，merge commit：

```text
c88b83362601e92bd18b18f0faf58c0a8adcd7ea
```

因此统一审计工具已经是 main 的正式能力，不要再把它当待实现功能。

## 二、语言与沟通要求

- 仓库说明、history、issue、交接文档默认使用**中文**。PowerShell 正式脚本为了 Windows PowerShell 5.1 编码兼容可以保持 ASCII-only，代码变量/输出可以是英文。
- 之前 `docs/history/2026-08-14-episode-metadata-refresh-root-cause.md` 一度被写成全英文，这是维护失误；在 `feat/tv-audit-export` 上已经翻译成中文。不要再把仓库 history 无理由写成英文。
- 用户不是 NAS/Jellyfin 专家，解释尽量直白，不要堆术语。
- 不要每个小选择都问用户；能明确推荐的就自己选。
- 用户不喜欢“请手动改第几行”。需要新脚本时，把完整脚本放进仓库，再给准确运行命令。
- 目标是把项目做好，不是把用户每句话机械地转成代码。如果外部能力未经验证、方向错了、架构和目标冲突，要主动指出。

## 三、当前范围与绝对边界

### 只处理 TV 动画

当前阶段只处理 `CollectionType=tvshows`。

**剧场版 `D:\Gekijouban` 继续冻结，不要拉进当前修复。**

原因：剧场版目录里混有剧场版、OVA、SP、特典等，问题比 TV 更复杂，以后单独处理。

### 原始文件

主要 TV：

```text
D:\Bangumi\...
```

另有：

```text
C:\bangumi
D:\Jellyfin-Repro   # test library
```

用户保留字幕组原始文件名，不希望重命名原始收藏文件。

### 项目输出目录

不要污染 `D:\` 根目录。项目生成内容固定放到：

```text
D:\Resource\BangumiLink\View\   # 长期 canonical Jellyfin view
D:\Resource\BangumiLink\Temp\   # staging / probe
D:\Resource\BangumiLink\Logs\   # manifest / audit / logs
```

历史 `D:\_jellyfin_repair_staging` 不要自动删除，除非确认已经为空。

### Jellyfin

```text
Version: 12.0.0
Server:  http://127.0.0.1:8096
```

API Key 是秘密。永远不要把旧 key 写进回复、仓库、日志或交接文档。

## 四、结构问题：已经确认到什么程度

### 1. NFO 能修 S/E，但不能解除错误 LocalAlternateVersion

仓库已经为此前明确的 243 个目标写过同名 episode NFO，只写：

```xml
<season>...</season>
<episode>...</episode>
```

Jellyfin 12 FullRefresh 已实验证明会尊重这些 NFO 的季号/集号。

但是后续确认：一些物理上不同的集数早已被 Jellyfin 分进同一个 LocalAlternateVersion group。NFO 可以让隐藏 child 的 `ParentIndexNumber` / `IndexNumber` 变正确，但不会可靠解除既有多版本关系。

### 2. 已确认的结构根因

单集 remove/readd 和跨作品实验确认：Jellyfin TV 在读取 NFO 之前就会进行路径/episode key 解析。

祖先目录例如：

```text
2026-01
2026-07
```

可能被宽泛的 `数字-数字` 规则识别，优先于字幕组文件名里的 `[09]` 等信息。不同物理 episode 因而先得到同一个错误 key，再被建立成 `LocalAlternateVersion`。

显式文件名：

```text
S02E09 - 原文件名.mkv
```

可以稳定让 Jellyfin 独立导入。

详见：

```text
docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md
```

### 3. canonical view 第一阶段已成功

正式工具：

```text
scripts/build_jellyfin_canonical_view.ps1
scripts/lib/canonical_view_common.ps1
```

设计：

```text
原始媒体不动
  -> authoritative S/E NFO
  -> 同盘 hardlink canonical video: SxxEyy - 原文件名
  -> NFO 复制到 View（不是 hardlink）
  -> Jellyfin 以后读取 View
```

第一阶段只处理 243 个 correction targets。

已经真实 Apply 成功并做第二次 dry-run：

- 243/243 video hardlink 已创建；
- 243/243 NFO 已复制；
- 0 preflight failures；
- 第二次 dry-run 243/243 reusable；
- 原始视频没有移动/修改。

**但当前 `View` 只有 243 个目标，不是完整 TV 库。绝对不能直接把生产 Jellyfin 从原目录切到这个 partial view；否则其他正常动画会消失。也不要让原始 TV roots 和 partial View 同时挂进生产库。**

结构 issue 继续看 #4。

## 五、2026-08-14 统一 TV audit 已经完成

正式工具已经合入 main：

```text
scripts/export_jellyfin_tv_audit_12.ps1
scripts/analyze_jellyfin_tv_audit.ps1
scripts/lib/tv_audit_common.ps1
```

本次完整 export 本地文件：

```text
D:\Resource\BangumiLink\Logs\jellyfin-tv-audit-2026-08-14.json
```

生成：

```text
D:\Resource\BangumiLink\Logs\jellyfin-tv-audit-2026-08-14-ledger.csv
D:\Resource\BangumiLink\Logs\jellyfin-tv-audit-2026-08-14-summary.md
```

用户已经在真实 Windows PowerShell 5.1 上验证：

```text
PASS: TV audit analyzer tests
PASS: PowerShell scripts are ASCII-only and parse successfully.
```

排除 `test` 后的最终统一基线：

```text
Series rows:                 56
Season rows:                 92
Expanded Episode rows:       676
Correction-target NFO rows:  243
Hidden Episode rows:         190
Hidden correction targets:   157
Hidden non-target rows:      33
Filesystem-only rows:        0
```

主要 issue labels：

```text
METADATA_MISSING_OVERVIEW: 44
METADATA_MISSING_PROVIDER_ID: 78
METADATA_REPEATED_TITLE_ACROSS_EPISODES: 264
REVIEW_EXTRAS: 63
REVIEW_NON_TARGET_HIDDEN: 33
SERIES_METADATA_MISSING_PRIMARY_IMAGE: 1
STRUCTURE_HIDDEN_ALTERNATE: 190
STRUCTURE_SEASON_MISSING_INDEX: 34
STRUCTURE_SUSPICIOUS_SEASON_NUMBER: 2
```

特别重要：filesystem 676 个视频和 expanded Episode 676 个路径一一对应，差集为 0。所以在**当前已经配置进 Jellyfin 的 TV roots** 里，没有发现“磁盘上有、Jellyfin expanded view 完全没有”的视频。

33 个 non-target hidden 不能自动处理，里面混有：真实/可能真实 v2 多版本、SP、OVA、NCOP/NCED、PV、menu、Bonus、特典等。

Season 层也不要忘：有 34 个缺正常季号、2 个异常 2025/2026 大季号，以及 Bonus/SPs/PV/menu/特典映像等被当成 Season 的情况。

## 六、243 个 NFO 的最终核对结果

本次 audit 成功读取：

```text
Same-name NFOs: 245
NFO summaries: 245
NFO read errors: 0
```

其中：

- 2 个来自 test；
- 243 个就是 production correction targets。

production 243 个全部满足：

- NFO S/E 与 Jellyfin expanded Episode 当前 S/E 一致；
- `title` 为空；
- `plot` 为空；
- provider unique id 为空。

因此 `Medalist`、`[晚街与灯`、`[FLsnow`、`Hyakkano` 等错误标题**不是 correction NFO 写进去的**。

## 七、当前 metadata 问题

这就是现在真正正在做的主线，见 issue #5。

### Medalist

13 个 correction targets：

- Provider ID：13/13 有；
- Overview：13/13 有；
- Primary image：13/13 有；
- 但标题主要仍是 `Medalist` / `Medalist[S2`；
- 其中还有 hidden alternate。

它是“其他在线 metadata 已经拿到了，但非空错误 Name 没被替换”的代表。

### Fate/strange Fake

14 个 correction targets：

- 13 个 hidden；
- Episode Provider ID：0/14；
- Overview：0/14；
- Primary image：14/14；
- 14/14 Name 都是 `[晚街与灯`。

它不是单纯标题覆盖问题，而是结构 + Episode provider metadata 明显不完整。

### 100 女友第三期

S03E01-S03E05 已正确且全部 normal visible，但：

- 5/5 Name 都是 `Hyakkano`；
- Episode Provider ID 只有 1/5；
- Overview 0/5；
- Primary image 5/5。

Series 本身已经有 IMDb/TMDb/TVDb ID 和 Overview，但缺 Primary image。

因此它不是“Series 完全没识别”，而是 Series 半成功、Episode metadata 不完整。

### 名侦探光之美少女

27 个 correction targets 全部 normal visible，但 27/27 Name 为 `[FLsnow`。这证明错误标题并不只是 hidden alternate 的副作用。

## 八、不要再误判 `EnableInternetProviders=false`

Jellyfin 12 源码里 `LibraryOptions.EnableInternetProviders` 已 obsolete；实际 remote metadata 是否可用应看各 `TypeOptions.MetadataFetchers`。

本机当前 Series / Season / Episode 的 TypeOptions 仍配置 TheMovieDb / The Open Movie Database 等 remote providers。

因此不能再说：

```text
EnableInternetProviders=false -> 全局关闭互联网 metadata
```

这个解释已经被否定。

## 九、当前最强 metadata 根因解释

之前为了安全修 S/E，实验长期使用：

```text
metadataRefreshMode=FullRefresh
replaceAllMetadata=false
imageRefreshMode=None
replaceAllImages=false
```

Jellyfin 12 当前源码已经确认：

- FullRefresh 会运行 metadata providers；
- 但 provider 结果最后合并到现有 item 时，`replaceAllMetadata=false` 不等于替换已有值；
- 对 `Name`，只有 `replaceData=true` 或当前 Name 为空时才覆盖；
- 所以已经非空的 parser fallback，例如 `Medalist`，会被保留；
- 空 Overview 仍可能补入，ProviderIds 也可能追加。

这高度吻合 Medalist 的现状。

中文调查文档：

```text
docs/history/2026-08-14-episode-metadata-refresh-root-cause.md
```

但是不要过度外推：这还不能解释 Fate / 100 女友为什么连 Provider/Overview 都不完整。

## 十、下一步：Medalist S02E01 单变量实验（尚未运行）

工作分支：

```text
feat/tv-audit-export
```

audit 已经合入 main，但这个分支上还保留了**尚未真实执行**的 metadata pilot：

```text
experiments/jellyfin12-nfo-refresh/17-medalist-e01-metadata-replace-pilot.ps1
tests/test_medalist_metadata_replace_pilot.ps1
```

关键 commits：

```text
5e5d2f15322f9d96f97829655b9607630046da25  test: define safe Medalist metadata replace pilot contract
289d264c0121735069c9ae13546c3331b4f8b49f  experiment: add guarded Medalist metadata replacement pilot
c0a999c80e32bf4dbe20e0ec01b231a653e97abd  docs: translate Episode metadata root-cause note to Chinese
```

目标固定为 Medalist S02E01：

```text
ItemId:   6993f67864a11e1151e7c9c6d3eee68d
SeriesId: 1e343af25a95b525ae23adc50142693a
Current:  S02E01
Name:     Medalist
```

脚本默认只读。Apply 前会检查：

- Item/Series ID 没变；
- 当前仍为 S02E01；
- 当前 Name 仍是 `Medalist`；
- 同名 NFO 为 S02E01 且 title 为空；
- Provider ID / Overview 仍存在；
- `SaveLocalMetadata=false`；
- `MetadataSavers` 为空；
- Nfo reader 开启；
- Episode remote MetadataFetchers 非空；
- 没有 `LockData=true`；
- `LockedFields` 不含 Name。

下一模型应先：

```powershell
git switch feat/tv-audit-export
git pull

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\test_medalist_metadata_replace_pilot.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\check_windows_powershell_compat.ps1
```

然后先 dry-run：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\experiments\jellyfin12-nfo-refresh\17-medalist-e01-metadata-replace-pilot.ps1 `
    -ApiKey "<API_KEY>"
```

如果明确 `Preflight passed`，再由用户运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\experiments\jellyfin12-nfo-refresh\17-medalist-e01-metadata-replace-pilot.ps1 `
    -ApiKey "<API_KEY>" `
    -Apply
```

这个 Apply 只对该 Episode 发一次：

```text
metadataRefreshMode=FullRefresh
replaceAllMetadata=true
imageRefreshMode=None
replaceAllImages=false
```

不请求 Series refresh，不替换图片，不改 NFO，不改媒体文件，不直接写 SQLite。

必须把结果回填 issue #5。

### 如果输出 `RESULT: NAME_REPLACED`

说明历史 `replaceAllMetadata=false` 确实是“在线 metadata 已存在但旧错误标题一直保留”这一类别的直接原因。

不要立刻全库 ReplaceAll。先根据 ledger 设计**有明确目标集和 preflight 的批量策略**，确保正确 S/E 不被破坏，并继续把 Fate / 100 女友当成另外的 provider 问题。

### 如果输出 `RESULT: NAME_UNCHANGED`

立即转向 remote provider lookup / provider 实际返回 / item lock，不要继续怀疑 sparse S/E NFO。

## 十一、之后如何协同推进

保持两条问题主线，但使用同一份 audit ledger 复核：

```text
结构 #4：S/E / Season / LocalAlternateVersion / full canonical view
metadata #5：Name / Overview / ProviderIds / image / provider lookup
```

不要做成两个互相忘记的项目。

推荐顺序：

1. 先完成 Medalist metadata 单变量实验并更新 #5；
2. 再分别诊断 Fate/strange Fake 和 100 女友第三期，不把它们强行套用 Medalist 结论；
3. metadata 修复机制确认后，设计安全批量修复；
4. 同时 #4 继续推进完整 TV canonical view（普通 TV 文件 pass-through hardlink，243 targets 用 canonical SxxEyy）；
5. 切换生产 TV library 前必须确认完整覆盖，不允许 partial View 上线；
6. 最后重新 export + analyzer，用统一 ledger 验证结构和 metadata 两条线都真正下降。

## 十二、Windows / 工具坑

- Windows PowerShell 5.1 对 UTF-8 无 BOM 的中文 `.ps1` 有历史解析问题，所以正式脚本尽量 ASCII-only；中文规则/文档可 UTF-8。
- 带 `[02]` 的路径不要用 PowerShell provider 的普通 hardlink 命令判断；仓库 canonical 工具使用 native `CreateHardLinkW`。
- 超长路径使用 native/extended path helper。
- `py -3` 在此机器是旧 Python 3.5 / SQLite 3.8.11。如果以后真的需要只读 SQLite 诊断，使用：

```text
C:\Users\34788\anaconda3\python.exe
```

它是 Python 3.13.5 / SQLite 3.45.3。

- `tv_audit_common.ps1` 当前 `Add-Type` 类型会在同一个 powershell.exe 进程里缓存。更新 native helper 后如果出现“明明 git pull 了却仍在运行旧实现”，先用**新的 `powershell.exe` 进程**验证。永久修复见 issue #8。

## 十三、不要做的事情

- 不要碰剧场版；
- 不要重命名原始字幕组视频；
- 不要直接写 Jellyfin SQLite 来“修关系”；
- 不要把 33 个 non-target hidden 全部自动改掉；
- 不要把 title 修复逻辑塞进 243-target canonical builder；
- 不要因为看见 `EnableInternetProviders=false` 就断言网络 metadata 被关闭；
- 不要把一次实验成功直接推广到全库；
- 不要在 issue / 文档 / 回复里泄露 API Key；
- 不要再次只追当前新问题而把 #4/#5 另一条主线忘掉。

接手后，先检查 open issues #4、#5、#8 和当前分支最新提交，再从 Medalist S02E01 dry-run 开始继续。

---
