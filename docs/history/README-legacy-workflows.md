# README 旧工作流与被移出内容说明

本文记录 2026-08-17 精简根目录 `README.md` 时移出的内容。

精简的目的不是删除历史，而是把 README 恢复为“现在维护 Jellyfin 时应该运行什么”的简短入口。此前 README 在项目推进过程中不断追加阶段性方案、调查结论和临时命令，逐渐同时承担了使用说明、交接文档和项目历史三种职责。随着主线稳定到“私有 manifest + 同盘 hardlink + 自动建库 + 增量维护”，这些旧阶段不再适合继续占据首页。

## 一、早期 NFO 纠错

旧 README 曾把 NFO 纠错作为第一项正式使用方法：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1
```

确认后：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1 -Apply
```

### 当时为什么加入

项目最初的目标很直接：字幕组文件名经常使用总话数、特殊写法或错误季号，希望通过最小 NFO 给 Jellyfin 明确写入 Season / Episode，从而不改原始视频文件名也能纠正识别。

因此仓库里形成了：

- `scripts/jellyfin_tv_nfo_fix.ps1`
- `rules/jellyfin_tv_nfo_rules.json`
- 一批 NFO 刷新、替换 metadata、provider identity 的测试与实验脚本

这条路线确实解决过“Episode 自己的季号、集号不对”这一类问题。

### 为什么后来退出主线

后续调查发现，Jellyfin 有一类更早发生的问题：在读取 NFO 之前，路径和文件名解析已经可能把多个视频错误建立为本地多版本关系（`LocalAlternateVersion` 等）。此时即使 NFO 能修正某个 Episode 自身的 Season / Episode，也不能稳定撤销已经形成的错误关系。

因此 NFO 不再适合作为全库整理的基础方案，主线转向“让 Jellyfin 一开始就看到规范文件结构”。

### 现在还能不能用

能，但属于**针对性旧工具**，不是当前日常入口。

如果以后遇到一个非常局部、明确只需要 NFO 的问题，相关脚本和规则仍可参考；但不应再默认用 NFO 管理整个动画库。

更完整记录见：

- `docs/nfo-refresh.md`
- `docs/history/2026-08-11-jellyfin12-nfo-refresh.md`
- `docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md`

## 二、Canonical View Phase 1：只处理已知错误目标

旧 README 曾保留：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

以及：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>" -Apply
```

当时说明它只处理约 243 个已经确认的 correction targets，并强调这是 partial view，不能单独替换生产 TV 库。

### 当时为什么加入

这是项目从 NFO 转向 hardlink 的第一步。

当时已经确认：如果不改原始收藏，就需要在同盘建立一个 Jellyfin 专用视图，把文件名变成显式 `SxxEyy - <原文件名>`，从输入端避免 Jellyfin 对字幕组命名的误解。

但那时还没有完整掌握全部库存，所以只敢对已知问题文件建立局部 canonical view。README 中保留“243 个 correction targets”和“不能替代生产库”的警告，是为了防止把实验性 partial view 当成完整库使用。

### 现在还能不能用

代码仍有历史和调试价值，但**已被完整 manifest hardlink 方案取代**。

当前不应该再以 Phase 1 作为生产维护入口。

设计背景见：

- `docs/canonical-view.md`

## 三、Canonical View Phase 2：完整库存调查

旧 README 曾写到，完整 TV View 从 PowerShell 实现切到 Python，并要求先运行：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

当时这一步只做 read-only inventory + mapping，用来解释 production filesystem 和 Jellyfin expanded Episode 的基线差异，并明确没有 `--apply`。

### 当时为什么加入

Phase 1 暴露出一个问题：只修“已知错误项”仍然建立在旧 Jellyfin 状态上，而旧状态本身已经混入路径误识别、重复版本和隐藏 Episode，不能再当事实来源。

因此项目进入第二阶段：先把真实文件系统与 Jellyfin 当前识别状态完整对账，搞清楚全量差异，再决定如何建立完整 View。

README 当时写得很详细，是因为这一阶段最大的风险就是“还没查清全量库存，就开始 apply”。

### 现在还能不能用

作为调查代码和历史实现仍可参考，但**不是当前主线**。

最终主线已经不再从 Jellyfin 反推真实库存，而是直接使用真实视频文件清单和人工判定 manifest。

## 四、720 文件人工判定与第一次完整重建

旧 README 后来增加“720 文件人工判定视图”章节，写明：

- 不再从旧 Jellyfin 识别状态反推库存；
- 以私有 720 行人工判定 manifest 为事实源；
- 用 `scripts/apply_anime_decision_manifest.py` 机械建立完整 hardlink View；
- C 盘目标为 `C:\resource\video\anime`；
- D 盘目标为 `D:\Resource\BangumiLink\View`。

对应命令：

```powershell
python scripts\apply_anime_decision_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --d-root "D:\Resource\BangumiLink\View"
```

### 当时为什么加入

这是项目真正从“修 Jellyfin”切换到“先把给 Jellyfin 的输入整理正确”的关键阶段。

第一次需要说明很多背景，因为当时必须明确：

- manifest 是人工审核后的语义事实源；
- 执行器本身不再猜作品和集数；
- 原始视频不移动、不重命名、不删除；
- 只在同盘建立 hardlink；
- D 盘旧重复 DIY 等条目可以在 manifest 中标记 IGNORE。

这些说明对于第一次大重建非常重要。

### 现在为什么从 README 压缩

这套方案**仍然是当前基础**，并没有废弃。

只是第一次施工过程已经结束。现在 README 只需要保留“如果要从 manifest 重建 hardlink，运行哪条命令”和最终目标目录即可；720 行如何产生、第一次为什么这样判定等内容应该留在历史文档里。

相关记录：

- `docs/history/2026-08-15-decision-manifest-apply.md`

## 五、自动重建 Jellyfin Libraries

旧 README 后来继续加入：

```powershell
$env:JELLYFIN_API_KEY = "<API_KEY>"
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

以及加 `--apply` 后一次性建库。

### 当时为什么加入

完整 hardlink View 建成以后，如果还要求手工在 Jellyfin Web 中逐个建立十几个季度/年份媒体库，就违背了整个项目自动化整理的目标。

因此新增脚本直接按 manifest 的 `LibraryGroup` 建库，同一个分组如果跨 C/D，则一次挂入两个 Locations；`剧场版` 使用 Movie library，其他动画分组使用 TV library。

之后又经历了 TMDB / TVDB provider 顺序的修正：当前目标是 TV 季/集 metadata 由 TVDB 优先，而图片由 TMDB 优先以获得中文海报；电影以 TMDB 为主要 metadata / image 来源。

### 现在还能不能用

**仍然是当前正式工具。**

所以精简后的 README 仍然保留了建库命令，只删除第一次开发、验证和 provider 调试过程的长篇说明。

相关记录：

- `docs/history/2026-08-15-library-rebuild-automation.md`

## 六、TV 动画统一审计导出

旧 README 保留了：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

### 当时为什么加入

项目早期一个很大的问题是：每次只能靠 Jellyfin UI 截图或零散描述判断元数据错误，无法把 Series / Season / Episode、Provider IDs、隐藏 Episode、NFO 和实际文件路径一次导出给人或 AI 检查。

因此增加统一 audit 导出，作为后续排查的观察入口。

### 现在还能不能用

**仍然有用，而且保留在精简 README。**

同时用户原本加入的“如果只想快速让 AI 核查一般 Jellyfin 元数据，可以使用 `docs/library-export.md` 中的通用导出脚本”也继续保留。

详见：

- `docs/library-export.md`

## 七、为什么不再在 README 逐条链接所有历史文档

旧 README 末尾曾继续列出 NFO 刷新、路径 parser、720 文件 Apply、自动建库等多份 history 文档。

这在项目快速推进、不同 AI 对话频繁交接时有实际价值：README 同时被当作一个简易“当前上下文索引”。

但仓库现在已经有：

- `docs/history/`：按阶段保存历史；
- `docs/handoff/`：交接信息；
- `docs/incremental-hardlink.md`：当前增量维护说明；
- `docs/library-export.md`：导出说明；
- `docs/canonical-view.md`、`docs/nfo-refresh.md`：特定历史路线说明。

因此 README 不再承担完整历史索引功能，只保留当前真正会运行的入口。

## 八、当前推荐入口

截至本次精简，日常维护只需要优先关心：

1. `scripts/update_anime_incremental_view.py`：新下载动画的增量 hardlink；
2. `scripts/apply_anime_decision_manifest.py`：必要时从私有 manifest 重建完整 hardlink View；
3. `scripts/create_jellyfin_libraries_from_manifest.py`：必要时重建 Jellyfin 动画库；
4. `scripts/export_jellyfin_tv_audit_12.ps1`：需要排查时导出当前 TV 元数据。

其他 scripts、rules、experiments、reports 和历史文档并未因此删除。它们继续作为调查记录、兼容工具或问题复现材料存在，但不再默认视为日常生产入口。
