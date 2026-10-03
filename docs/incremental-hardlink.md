# 新下载动画的增量 hardlink 维护

720 文件首次整理完成后，日常追番不再生成 NFO，也不需要重新制作整张 manifest。

入口：

```text
scripts/update_anime_incremental_view.py
```

## 日常使用

先 dry-run：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

脚本默认完整扫描：

```text
D:\Bangumi
C:\bangumi
```

另外扫描 `E:\Bangumi` 中**已经登记在私有 manifest 的作品目录**，不遍历 E 盘未登记的作品。2026-10-04 已登记这批 12 部作品的 125 个现有硬链接；《アオアシ》尚未下载完，不在登记范围内。5 个已知的 Menu、NCOP、NCED 文件只记为排除项，不创建正片链接。

归档先遵守年代分组：2023 年及以前用 `YYYY年动画`，例如 2022 年作品放 `2022年动画`，不能新建 `2022年07月新番` 之类的目录。2024 年及以后已按季度组织的作品，才使用该季新作所属的季度，而不是整个系列的首播季度。例如续作可沿用系列名与 `Season 02`，但《正反対な君と僕》第二季的顶层是 `2026年07月新番`。脚本会拒绝把 2023 年及以前的已登记 TV 正片写入季度“新番”分组。

并使用现有目标根：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
E:\Resource\BangumiLink
```

关注输出：

```text
Auto-classified: N
Needs review:    0
```

只有 `Needs review: 0` 时才建议执行：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

`--apply` 会：

1. 只处理 manifest 中不存在的新视频；
2. 根据既有人工确认映射推导作品、Season/Episode 和目标路径；
3. 先检查所有新目标是否冲突；
4. 创建同盘 hardlink；
5. 成功后把新行原子追加到私有 manifest；
6. 中途失败时回滚本轮新建的 hardlink。

## 能自动处理什么

适合已经存在于 manifest 中、继续更新的新集。

- 文件名显式包含 `SxxEyy`：直接使用；
- 字幕组使用总话数：从该作品历史 manifest 推导偏移，例如百女友第三季 `25 -> S03E01`，后续 `31 -> S03E07`；
- 字幕组更换、作品目录下多套一层文件夹：只要仍在已知作品根目录下且集数可高置信解析，也可以继续处理。

《ワールド イズ ダンシング》从 Studio GreenTea 换到 Nix-Raws、并出现额外字幕组子目录，就是这一情况。

## 什么不会自动做

- C/D 盘全新作品第一次出现：没有历史映射时输出 `[REVIEW]`；
- E 盘全新作品第一次出现：不会扫描，须先人工确认作品、季度、季数并登记到 manifest，之后才会自动追新集；
- 无法可靠判断集数的文件：输出 `[REVIEW]`；
- 历史上明确属于 extras 的子目录：不自动把数字解释成 Episode；
- 不生成或修改 NFO；
- 不调用 Jellyfin 去猜作品身份。

存在任何 `[REVIEW]` 时，脚本拒绝 `--apply`。这条限制是为了让“日常新集自动化”不重新变回高风险的文件名猜测器。

需要改变默认根目录时，分别用可重复的 `--source-root`（完整扫描）或 `--tracked-source-root`（仅已登记作品）；目标视图用 `--c-root`、`--d-root`、`--e-root`。不要把整个 `E:\Bangumi` 传给 `--source-root`，否则未完成作品也会进入人工审核列表。
