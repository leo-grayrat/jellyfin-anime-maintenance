# 2026-08-12 Jellyfin 12 路径解析与错误多版本关系调查

本文承接 `2026-08-11-jellyfin12-nfo-refresh.md`，记录在 NFO 季/集号已经修正之后，为什么 Jellyfin UI 仍会把不同 Episode 折叠成同一个“多版本”条目，以及最终验证出的可行规避方向。

一次性实验脚本和脱敏结果位于：

```text
experiments/jellyfin12-nfo-refresh/
```

## 问题现象

全局 alternate-group 审计发现：243 个 NFO correction target 中，大量 Episode 虽然自己的 `ParentIndexNumber` / `IndexNumber` 已经正确，却仍处在旧的 alternate group 中。典型例子是《金牌得主》第 2 季：S02E02 到 S02E09 共 8 个物理文件，在 UI 中被折叠到一个 Episode 下。

数据库只读诊断进一步确认，S02E03-S02E09 不是普通 `LinkedAlternateVersion`，而是 `LocalAlternateVersion`：

- owner S02E02 的 `Data.LocalAlternateVersions` 保存 7 个其他物理文件路径；
- `LinkedChildren` 中有 7 条 `ChildType=2 (LocalAlternateVersion)`；
- 7 个子项的 `OwnerId`、`PrimaryVersionId`、`PresentationUniqueKey` 都指向或等同于 owner；
- 子项自身的季/集号已经分别是 S02E03-S02E09。

这说明 NFO 修正解决的是“这个文件属于哪一季哪一集”，但没有自动拆掉已经建立的“这些文件是同一个 Episode 的不同版本”关系。

## 实验 1：官方 AlternateSources DELETE 无法解决

`09-medalist-alternate-split-pilot.ps1` 调用：

```text
DELETE /Videos/{itemId}/AlternateSources
```

结果没有让隐藏的 Episode 恢复正常可见。随后数据库诊断证明该组是 `LocalAlternateVersion`，而不是该 API 面向的 `LinkedAlternateVersion`。

因此这一接口不再作为当前修复入口。

## 实验 2：原文件移出再原样移回，会重新错误合并

脚本：

```text
12-medalist-e09-remove-readd-pilot.ps1
```

只选《金牌得主》S02E09：

1. 将视频和同名 NFO 暂时移到 Jellyfin 库外；
2. 等待实时监控删除旧 Episode；
3. 确认 owner 的 media-source count 从 8 降为 7，S02E09 从 expanded view 消失；
4. 把完全相同的视频和 NFO 原样移回原路径；
5. 观察 Jellyfin 重新导入。

实际结果：

```text
ownerSources=8
ownerHasTarget=True
Target normally visible=False
Target expanded visible=True
Target current key=S02E09
Target media-source count=8
```

结论：**错误关系不是单纯的历史数据库残留。** 旧关系在文件移出时已经被 Jellyfin 删除，但原文件重新出现后，当前 Jellyfin 12 扫描流程会再次主动创建同样的 LocalAlternateVersion group。

脱敏结果：

```text
results/14-medalist-e09-remove-readd-remerged.txt
```

## 源码定位：alternate group 在 NFO 修正前由路径解析结果决定

在 Jellyfin v12.0-rc5 中，TV 库的多文件解析会进入 `VideoListResolver.GetEpisodesGroupedByVersion()`。

其核心行为是：

1. 对每个视频的完整路径调用 `EpisodePathParser.Parse(...)`；
2. 根据解析出的 season / episode 构造类似 `S2E9` 的 key；
3. key 相同的多个文件立即组织成 alternate versions；
4. `MovieResolver` 随后把这些路径写入 `LocalAlternateVersions`；
5. 后面的 NFO metadata merge 可以把各隐藏 item 的季/集号改正确，但不会因此撤销已经建立的 local-alternate 结构。

这解释了为何会出现看似矛盾的状态：一个隐藏 item 自己已经是 S02E09，但仍然是 S02E02 的 local alternate。

## `YYYY-MM` 目录为何危险

当前媒体库大量采用类似：

```text
D:\Bangumi\2026\2026-01\作品目录\字幕组文件名.mkv
```

Jellyfin 的 episode 表达式中存在一条较宽松的规则：

```regex
([0-9]+)-([0-9]+)
```

其本意是识别类似 `1-12 episode title` 的命名，但 `EpisodePathParser` 接收的是完整路径。于是祖先目录中的：

```text
2026-01
2026-04
2026-07
2025-10
```

也可能先被这条规则匹配。

解析器按规则顺序工作，遇到第一个成功结果就停止；而 Jellyfin 对异常 season 的过滤又不会排除 2025 / 2026 这类数值。因此同一季度目录下的一组视频可能在“建立多版本关系”这一早期阶段统一得到同一个错误 key，例如 `S2026E1`。

之后 NFO 再把各 item 修成 S02E02、S02E03……已经来不及阻止它们被当作同一 Episode 的多个本地版本。

## 实验 3：显式 `SxxEyy` 文件名前缀成功阻止重新合并

脚本：

```text
13-medalist-e09-canonical-name-pilot.ps1
```

实验仍只使用同一个 S02E09，唯一变化是重新放回时把文件名改为：

```text
S02E09 - <原字幕组文件名>.mkv
S02E09 - <原字幕组文件名>.nfo
```

先确认旧文件已经完全移出、owner 降为 7 sources，再以新名称加入。

最终稳定结果：

```text
Owner source count:        7
Owner contains canonical:  False
Target normally visible:   True
Target expanded visible:   True
Target current key:        S02E09
Target media-source count: 1
Visible through Series:    True
```

Jellyfin 为它创建了新的独立 Episode Item，而不是重新并回 S02E02。

脱敏结果：

```text
results/15-medalist-e09-canonical-name-independent.txt
```

## 当前结论

截至 2026-08-12，这条因果链已经由连续实验基本闭合：

```text
原始季度路径含 YYYY-MM
        ↓
EpisodePathParser 在完整路径上先命中错误规则
        ↓
不同物理 Episode 得到相同的早期 season/episode key
        ↓
VideoListResolver 将其组织为 LocalAlternateVersion
        ↓
后续 NFO 能修正每个 item 的季/集号
        ↓
但不会自动拆掉已经建立的多版本关系
```

对同一个 S02E09：

- 原名移回：重新合并为 8-source LocalAlternateVersion group；
- 显式 `S02E09` 前缀移回：保持独立，正常出现在 Series 中。

因此，对本服务器而言，**不应把“直接清理 jellyfin.db 的错误 alternate 关系”作为长期主方案**。即使数据库当下被清干净，只要 Jellyfin 继续看到同样的原始路径/文件名，扫描时仍可能再次制造错误关系。

## 阶段复盘：NFO 修复路线为何到这里结束

这一轮调查最初的设想很直接：先判断每个文件正确的作品、季号和集号，写入 NFO，再让 Jellyfin 重新读取。若问题只是“缺少或识别错了元数据”，这条路线本应足够。

实际实验也证明了它并非完全无效：Jellyfin 12 的 Episode FullRefresh 确实会读取 NFO 中的 `<season>` / `<episode>`，Series FullRefresh 在目标 Season 已存在时也能重新挂接 SeasonId。早期批量结果中的“230/243 OK”，正是这一层修正成功的表现。

但后来确认，**“Episode 自己的季/集号正确”与“它在 Jellyfin 中是独立 Episode”是两个不同层次的问题。** 一个隐藏 item 可以已经是 S02E09，同时仍被 Jellyfin 作为 S02E02 的 `LocalAlternateVersion`。NFO 能改正 item metadata，却不会因为新的 S/E 值而自动撤销已经建立的 alternate relationship。

进一步的移出—原样移回实验排除了“只是一批历史脏关系”的解释：文件移出后旧关系确实消失，但原名重新加入时，当前 Jellyfin 扫描流程会再次主动建立同样的错误组。也就是说，即使手工或脚本清理数据库，只要输入路径保持原样，错误仍可能在下一次扫描中重现。

源码与 canonical-name 实验最终把原因闭合为一个顺序问题：Jellyfin 会在 NFO 元数据合并之前先解析完整路径并组织本地多版本；祖先目录中的 `YYYY-MM` 可能被宽松 episode 规则提前命中，使本来不同的物理 Episode 获得相同的早期解析 key。后续 NFO 虽然能把各 item 的 S/E 修正确，却不会回头重建已经形成的 LocalAlternateVersion 结构。

因此，到这里应当明确区分两件事：

- **把 NFO 当作“最终修复手段”的路线基本结束。** 仅靠写 NFO + refresh，无法稳定解决本轮已经确认的错误多版本关系。
- **NFO 作为正确身份信息并没有失效。** 现有规则、run log 和 NFO 仍然是我们掌握的权威 S/E 数据，后续规范视图正是依靠这些信息生成明确的 `SxxEyy - <原文件名>` 输入。

换言之，仓库最初较窄的目标——“生成正确 NFO 后直接让 Jellyfin 恢复正常”——已经被实际行为推翻；但更上层的目标没有改变：**维护非标准动漫资源，使 Jellyfin 获得正确、可重复、可审计的媒体结构。** 实现路径只是从“修正 Jellyfin 已经识别后的 metadata”转向“给 Jellyfin 提供从第一步就不容易被错误解析的规范输入”。

这也是后续架构变化的核心：

```text
原始字幕组文件
        ↓
规则 / NFO / correction target 提供正确身份
        ↓
生成 Jellyfin 专用规范路径
        ↓
SxxEyy - <原文件名>
        ↓
Jellyfin 从输入阶段开始正确识别
```

## 后续验证：跨作品 hardlink

在《金牌得主》单文件实验后，又选择《描绘直至生命尽头》S01E02 做跨作品验证。

最初的 `14-cross-series-canonical-hardlink-pilot.ps1` 使用 PowerShell：

```powershell
New-Item -ItemType HardLink
```

结果在带 `[02]` 的字幕组路径上失败。随后 `15-hardlink-path-probe.ps1` 证明：

- `Test-Path -LiteralPath` 可以看到 source；
- 普通 `-Path` 会把 `[]` 当 wildcard；
- PowerShell hardlink provider 报 source 不存在；
- native `CreateHardLinkW` 可以成功创建同一条 hardlink。

因此正式实验改为 `16-cross-series-canonical-native-hardlink-pilot.ps1`。

跨作品 Apply 最终得到：

```text
Target normally visible: True
Target expanded visible: True
Target current key:      S01E02
Target media-source count: 1
Visible through Series:  True
RESULT: CANONICAL HARDLINK STAYS INDEPENDENT
Cleanup status: RESTORED
```

这说明“显式 `SxxEyy` + hardlink 规范视图”的效果不仅存在于《金牌得主》单一案例中，而且不需要修改原始视频文件名。

脱敏结果：

```text
results/16-hardlink-path-probe-powershell-provider.txt
results/17-cross-series-canonical-native-hardlink-success.txt
```

## 2026-08-13：243-target 规范视图真实构建

在单点验证结束后，正式脚本：

```text
scripts/build_jellyfin_canonical_view.ps1
```

以当前 `jellyfin_tv_nfo_run_log.csv` 中 243 个 correction targets 为输入进行全量 preflight。

期间实际暴露并修正了两个正式构建边界：

1. Windows PowerShell 5.1 / .NET Framework 的 `Path.GetPathRoot()` 会在部分超长字幕组路径上触发传统 `MAX_PATH` 异常，因此正式脚本不再用它解析卷根，并对 hardlink / copy / directory 等关键文件操作使用 native Windows API；
2. Jellyfin `/Library/VirtualFolders` 的 PowerShell 返回值曾被错误当作单个对象，导致多个 library name 被拼成一个字符串；修正为显式展开后，243 个 target 均能映射到正确的独立媒体库路径。

最终真实 Apply：

```text
planned targets = 243
preflight failures = 0
canonical videos ready = 243
canonical NFOs ready = 243
videos created = 243
videos reused = 0
NFOs created = 243
NFOs reused = 0
source media modified = 0
source media moved = 0
unmanaged target overwritten = 0
manifest ready = true
build log ready = true
```

随后再次 dry-run：

```text
Existing manifest rows: 243
Planned targets:      243
Preflight failures:   0
Videos reusable:      243
Videos to create:     0
NFOs reusable:        243
NFOs to create:       0
```

因此第一版 243-target canonical View 的**构建与幂等复用行为已经完成真实环境验证**。

当前规范目录为：

```text
D:\Resource\BangumiLink\
├─ View\
├─ Temp\
└─ Logs\
```

详细操作与 manifest / rollback 说明见：

```text
docs/canonical-view.md
```

## 当前阶段边界

这次成功并不意味着现在就可以把主 Jellyfin TV 库直接切到 `View`。

第一版 View 只包含 243 个 correction targets，而不是完整 TV 库：

- 只扫描 View，会让其余正常动画消失；
- 同时扫描原始路径和 View，会让这 243 个目标重复出现。

因此，**243-target View 是规范视图生成器第一阶段的最终产物，不是最终切库产物。**

下一阶段如果继续，应构建完整 TV 规范镜像：正常文件透传 hardlink，已知 correction targets 使用 canonical `SxxEyy` 名称，同时保留合法同集多版本和必要 sidecar。等完整 View 足以替代原 TV 库后，再单独设计 Jellyfin 的最终切换步骤。
