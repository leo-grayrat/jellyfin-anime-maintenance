# 2026-08-14 Episode 元数据刷新根因调查

## 背景

TV 动画统一审计确认：很多 Episode 的季号/集号已经正确，但标题仍然保留从文件名解析出来的错误结果或跨集重复结果，例如 `Medalist`、`Medalist[S2`、`[FLsnow`、`Hyakkano`。

当前 243 个生产 correction NFO 只写季号/集号，`title` 和 `plot` 都为空，也没有 provider unique id。因此这些错误 Episode 标题并不是 correction NFO 写进去的。

## 之前实际使用的刷新参数

早期 NFO 修正实验有意使用：

```text
metadataRefreshMode=FullRefresh
imageRefreshMode=None
replaceAllMetadata=false
replaceAllImages=false
```

这是当时为了验证 Jellyfin 12 能否接受 NFO 中的季号/集号，同时尽量避免大范围替换既有 metadata 而采用的保守设置。

## Jellyfin 12 源码行为

Jellyfin 12 当前 metadata 刷新逻辑中，`FullRefresh` 或 `ReplaceAllMetadata` 都会让 metadata provider 参与刷新。

处理 provider 时，只要没有开启本地 metadata 保存并同时要求 `ReplaceAllMetadata`，本地 metadata 仍然可以被读取。当前审计到的 TV 库均为 `SaveLocalMetadata=false`，`MetadataSavers` 为空，同时 Nfo 本地 reader 仍然启用。

真正决定旧标题是否被覆盖的是 provider 结果最后合并回现有条目时的 replacement 逻辑。大致可以理解为：

```text
shouldReplace = Full-or-higher refresh AND ReplaceAllMetadata
                OR Default refresh without ReplaceAllMetadata
```

对于我们历史上使用的 `FullRefresh + replaceAllMetadata=false`，`shouldReplace` 为 false。

Base item 的合并逻辑只有在以下任一条件成立时才会覆盖 `Name`：

```text
replaceData == true
```

或者现有目标 `Name` 本来就是空的。因此，一旦文件名解析已经留下一个非空的错误标题，例如 `Medalist`，这种刷新模式即使从 provider 得到了更好的标题，也会保留现有 Name。

相比之下，如果 Overview 原本为空，它仍然可以被补上；ProviderIds 也可以在不替换全部既有 metadata 的情况下加入。这与 Medalist 当前状态高度吻合：Provider ID、Overview、图片都存在，但旧的非空 `Medalist` Name 一直保留下来。

## 当前结论

这已经能很好地解释一类重要的 metadata 故障：

> 之前为了安全修 S/E 使用的刷新方式适合修季号/集号，但 `FullRefresh + replaceAllMetadata=false` 本身不是“替换错误标题”的操作。对于已经非空的 fallback Episode Name，它会选择保留。

但这还不能解释所有 metadata 问题：

- Fate/strange Fake 同时缺 Episode ProviderIds 和 Overview，所以仍然需要继续调查 provider lookup、身份识别以及 alternate owner/child 的影响；
- 100 女友第三期的 Series 只完成了部分识别，而 Episode metadata 仍不完整，也需要单独调查 provider lookup。

因此，不能把所有 metadata 问题都简单归结为 `replaceAllMetadata=false`。

## 受控验证实验

下一步实验刻意只选择 Medalist S02E01：

```text
6993f67864a11e1151e7c9c6d3eee68d
```

选择它的原因：

- 当前正常可见；
- 已经是正确的 S02E01；
- 同名 correction NFO 也是 S02E01，且 title 为空；
- 已经有 Provider ID、Overview 和主图片；
- 当前 Name 仍然是 `Medalist`。

对应的受保护实验脚本是：

```text
experiments/jellyfin12-nfo-refresh/17-medalist-e01-metadata-replace-pilot.ps1
```

默认执行只做只读 preflight。只有显式传入 `-Apply` 才会对这一个 Episode 发：

```text
metadataRefreshMode=FullRefresh
imageRefreshMode=None
replaceAllMetadata=true
replaceAllImages=false
```

在发 POST 之前，脚本会检查固定 ItemId / SeriesId / S02E01 状态、同名稀疏 NFO、当前媒体库 metadata 保存设置、Episode metadata fetcher 是否开启，以及是否存在全局锁或 Name 锁。任一条件不满足都会拒绝执行。

如果刷新后 Episode Name 改变，而 S02E01 仍保持正确，就可以实验证实“历史 `replaceAllMetadata=false` 保留错误标题”这一机制。如果 Name 仍然是 `Medalist`，下一步就应转向远程 provider lookup、provider 实际返回内容或锁定行为，而不是继续怀疑稀疏 S/E NFO。

在这个单集实验得到结果之前，不应批量执行 metadata replacement。
