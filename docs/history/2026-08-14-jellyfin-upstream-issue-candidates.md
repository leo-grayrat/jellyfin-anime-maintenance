# 2026-08-14 Jellyfin 上游 issue 候选记录

本文最初用于记录 Jellyfin 12.0.0 排障过程中出现的上游 issue 候选。2026-08-16 在媒体库重建基本完成后重新梳理：此前“当前只有候选 1”的判断已经过时。现在应把不同层次的问题拆开，不再把“为什么会误绑”“误绑后为何不解绑”“官方解绑 API 是否覆盖这种关系”混成一个巨大 issue。

## 2026-08-16 当前上报队列

### READY：Episode 的 S/E 已改成不同集，但既有 LocalAlternateVersion 关系不会自动解除

**状态：已经完成实机实验，达到可以直接整理几段文字上报的程度，不再在本项目里继续研究。**

已经确认的事实：

- 多个物理 Episode 曾被 Jellyfin 绑定为同一 Episode 的本地多版本；
- 后续 NFO / metadata refresh 已经把这些隐藏 item 的 `ParentIndexNumber` / `IndexNumber` 修成彼此不同的 S/E；
- 例如《金牌得主》第 2 期中，隐藏成员已经分别是 S02E03-S02E09，但仍全部挂在 S02E02 的 LocalAlternateVersion group 下；
- 普通 Series 查询仍看不到这些 hidden members；
- 数据库确认该关系由 `LocalAlternateVersion`、`OwnerId`、`PrimaryVersionId`、共同 `PresentationUniqueKey` 等状态维持。

要报告的单一问题不是“最初为什么会误绑”，而是：

> 当 Episode 的身份元数据已经被明确修改成不同的 Season/Episode 后，Jellyfin 没有重新验证并解除已经失效的 local alternate relationship，导致 item metadata 与 library structure 长期互相矛盾。

详细证据见：

- `2026-08-11-jellyfin12-alternate-groups.md`
- `2026-08-12-jellyfin12-path-parser-and-alternate-version.md`

---

### HIGH：祖先目录中的 `YYYY-MM` 被 EpisodePathParser 当成 episode range，导致不同 Episode 自动合并为 LocalAlternateVersion

**状态：生产环境因果链已经非常强，但上报前仍应做一个干净、最小、自包含的 test-library reproduction。**

当前已确认：

```text
D:\Bangumi\2026\2026-01\作品目录\字幕组文件名.mkv
```

这类路径会把完整 path 交给 `EpisodePathParser`。Jellyfin 当前 master 仍存在宽松表达式：

```regex
([0-9]+)-([0-9]+)
```

其注释目标是 `1-12 episode title`，但 parser 接收完整路径，因此祖先目录 `2026-01` 也可能命中。

随后 `VideoListResolver.GetEpisodesGroupedByVersion()` 会直接根据 `EpisodePathParser.Parse(video.Files[0].Path, false)` 的结果构造 `S{season}E{episode}` key，并把 key 相同的多个文件交给 `OrganizeAlternateVersions()`。也就是说，多版本关系在 NFO/provider metadata merge 之前就可能被建立。

本机连续实验已经证明：

- 把 S02E09 移出 library 后，旧关系消失；
- 完全原名移回，会再次自动并回错误 group；
- 唯一改变为显式 `S02E09 - <原文件名>` 后重新加入，则保持独立；
- 跨作品 hardlink 实验也复现了 canonical `SxxEyy` 名称可避免错误合并。

这已经排除了“只是旧数据库脏关系”的解释。

仍需补的只有：在全新小测试库中，用 2-3 个 dummy 文件和最短目录结构复现，从而把动漫字幕组、720 文件 manifest 等背景全部剥离掉。

上游历史 issue #14080 曾出现过 Episode parser 从路径/名称数字中产生 false positive 的相邻问题，但没有发现现有 issue 报告“祖先 `YYYY-MM` → range parser → LocalAlternateVersion 自动合并”这条完整链路，因此目前不像 duplicate。

---

### HIGH / NEAR-READY：`DELETE /Videos/{id}/AlternateSources` 对 LocalAlternateVersion 返回成功但完全不解绑

**状态：已有 Medalist pilot 和数据库证据；是否单独上报主要取决于如何界定 API 语义，不需要再重复做同一个生产实验。**

已有实机结果：

```text
DELETE /Videos/{ownerId}/AlternateSources
```

返回成功，但：

- owner source count 不变；
- hidden Episode 不恢复；
- LocalAlternateVersion link 不变。

随后 SQLite 只读诊断确认该 group 完全是 `ChildType=2 (LocalAlternateVersion)`，没有 `LinkedAlternateVersion`。

当前 Jellyfin master 的 controller 文档把 endpoint 描述为：

> Removes alternate video sources.

但实现只遍历 `GetLinkedAlternateVersions(item)` 并清理 `LinkedAlternateVersions` / `PrimaryVersionId`，没有处理 `LocalAlternateVersions`、对应 local link 和 `OwnerId`。

因此表面 API 语义与实际覆盖范围存在明显落差。上游搜索暂未找到 `AlternateSources` / LocalAlternateVersion 的同类 issue。

这一条应与 READY 项分开：

- READY 项：metadata identity 改变后，Jellyfin 是否应自动重新验证 stale local-alternate relationship；
- 本项：管理员显式调用“Remove alternate video sources”接口时，为什么 local alternates 根本不在处理范围内。

---

### MEDIUM：`FixIncorrectOwnerIdRelationships` migration 对 Episode 的覆盖缺口

**状态：源码缺口明显，但暂时不抢在上面两条之前上报。**

Jellyfin 当前 migration `FixIncorrectOwnerIdRelationships` 的注释明确说明，它用于修复 auto-merge 导致的错误 `OwnerId` parent-child 关系，并清理 alternate version 遗留。

但 `ClearIncorrectOwnerIdsAsync()` 的类型筛选只包含：

- `MediaBrowser.Controller.Entities.Video`
- `MediaBrowser.Controller.Entities.Movies.Movie`

没有 `MediaBrowser.Controller.Entities.TV.Episode`。

本机受影响对象恰好全部是 Episode，并确认隐藏 children 持有错误/stale `OwnerId`。

但这条目前有两个原因不优先独立提交：

1. 当前扫描流程仍可以重新制造错误 local alternate group，因此 migration omission 并不是根因；
2. 需要先判断上游维护者是否把 Episode 排除视为有意设计，还是迁移时漏掉一种 Video subtype。

更适合作为 READY / AlternateSources issue 的补充源码线索，除非后续能构造一个“升级前存在 Episode stale OwnerId，升级后 migration 明确漏清”的独立升级复现。

---

### LOW：ReplaceAll 在 provider metadata 不完整时可能造成既有 Overview 丢失

**状态：保留候选，但不是当前最值得投入时间的上游 issue。**

对 Medalist S02E01 做受控 `FullRefresh + replaceAllMetadata=true` 后，原先存在的 Overview 被清空，而 Name 仍保持旧值。

当前源码中的字段合并存在一个值得注意的不对称：

- 新 `Name` 为空时，有显式 safeguard，不会用空值覆盖旧 Name；
- 新 `Overview` 为空时，replace 模式允许覆盖旧 Overview。

因此，当一次 ReplaceAll 得到的是“不完整的 provider metadata”时，可能发生：

```text
旧 Name      -> 保留
旧 Overview  -> 被清空
```

但在提交前仍需区分：

1. provider lookup 输入错误；
2. lookup 正确，provider 确实返回空 Overview；
3. provider 返回了 Overview，但 mapper 丢失。

并且 `replaceAllMetadata=true` 本身是否允许清空 provider 未返回字段，也可能被上游视为设计语义。因此当前优先级低于结构类问题。

---

## 已排除 / 暂不作为上游 issue

### TMDB Episode 返回 no metadata

Frieren S2 / Oshi no Ko S3 等案例最终确认主要来自本地 Season 模型与 TMDB 数据模型不一致，而不是 Jellyfin 明明查询到存在的 S/E 却返回空。

因此不报 Jellyfin provider bug。

### Special 出现在主 Season

Jellyfin 有“在实际播出季中显示 Special”一类展示逻辑。仅凭 S00 item 同时出现在 Season 1 不能认定为 server bug；不进入当前上游队列。

### BD extras / PV / NCOP 等展示方式

`extras` 下的视频不是 Episode，客户端如何呈现需要先区分 server 数据模型与 client UI。当前没有足够证据，不报。

### S00 / Special metadata 未匹配

本项目最终确认过 TVDB / TMDB provider 顺序曾被错误配置，且不同数据库的 Special 编号本身差异很大。没有先消除 provider-order 与数据库建模差异前，不能把这些现象报成 Jellyfin bug。

### IPv6 设置保存时出现一次 Axios 404

重启 Jellyfin 后恢复正常，未能稳定复现，不报。

---

## 当前真正的执行顺序

1. **READY 项直接准备 upstream issue 文本，不再继续实验。**
2. 给 `YYYY-MM` parser 问题做一个最小独立 test-library reproduction；成功后单独上报。
3. `AlternateSources` LocalAlternateVersion no-op 已有足够生产证据；先核对上游对 endpoint 的预期语义，再决定直接报 bug 还是 API/feature gap。
4. migration omission 暂时作为源码线索，不急着单开。
5. ReplaceAll/Overview 放到结构类问题之后。

原则仍然是：**一个上游 issue 只报告一个行为，不把整个项目历史和所有 Jellyfin 怪现象塞进同一张单。**
