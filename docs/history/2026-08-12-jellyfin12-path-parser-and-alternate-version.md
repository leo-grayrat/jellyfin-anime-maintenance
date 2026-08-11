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

## 后续方向：规范 Jellyfin 的输入视图

下一阶段暂不改原始收藏目录。更合适的方向是给 Jellyfin 提供一层独立的“规范视图”，让 Jellyfin 看到明确、稳定的文件名，例如：

```text
S02E02 - <原文件名>.mkv
S02E03 - <原文件名>.mkv
...
S02E09 - <原文件名>.mkv
```

原始字幕组文件名和年度/季度归档结构可以保持不动。规范视图可考虑通过同盘硬链接等方式建立，并同步生成同 basename 的 NFO。

在真正批量实现前，还应注意两类边界：

- 同一 S/E 的合法多版本不能被错误拆散；
- alternate group 中存在 correction target 之外的未知成员时，不能按已知目标盲目重建。

因此下一阶段脚本应以“生成/维护 Jellyfin 专用规范视图”为核心，而不是继续扩大数据库直接修复。
