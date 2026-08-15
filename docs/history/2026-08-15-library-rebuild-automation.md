# 2026-08-15 基于 manifest 自动重建 Jellyfin 库

对应 Issue：#13。

## 目标

文件层已经通过最终 dry-run 闭环：720 行 manifest 中 708 条为实际整理项、12 条为 `IGNORE`，实际目标全部可复用。

下一步不再手工逐个创建 Jellyfin 库，而是让脚本根据同一份私有 manifest 自动建立最终库。

## 最终库名策略

本阶段不使用 `新视图-`、`测试-` 等临时前缀。

用户的实际流程是：

1. 先删除不再需要的旧 Jellyfin 动画库；
2. 保留已经建立好的新硬链接目录；
3. 由脚本直接按最终 `LibraryGroup` 名称一次性建立新库。

因此库名直接等于 manifest 的 `LibraryGroup`，例如：

- `2022年动画`
- `2025年01月新番`
- `2025年04月新番`
- `2026年01月新番`
- `剧场版`

不先创建临时名称，也不安排第二轮 Rename。

脚本不会删除旧库。如果同名库仍存在但类型或 Locations 与计划不同，preflight 报 `CONFLICT` 并停止；用户先完成旧库清理后再运行即可。

## 自动化规则

新增：

```text
scripts/create_jellyfin_libraries_from_manifest.py
```

脚本从私有 manifest 的 `CONFIRMED` 行生成库计划：

- 按 `LibraryGroup` 聚合；
- `TV_MAIN / TV_EXTRA / TV_SPECIAL / U149_MULTI / ANOTHER_WORLD` → `tvshows`；
- `MOVIE / MOVIE_EXTRA` → `movies`；
- 同一 `LibraryGroup` 如果同时存在 C:/D: 来源，则同一个 Jellyfin library 自动挂两个 Locations；
- C 盘根固定为 `C:\resource\video\anime`；
- D 盘根固定为 `D:\Resource\BangumiLink\View`；
- `IGNORE` 行不参与建库；
- `TargetRelativePath` 第一层必须与 `LibraryGroup` 一致，否则拒绝运行；
- 同一组如果混入 TV 与 Movie bucket，拒绝运行。

默认是 dry-run。显式 `--apply` 后，只创建当前缺失的库。每个库创建时设置 `refreshLibrary=false`，全部创建完后只触发一次全库扫描。

## 安全边界

脚本只管理 manifest 中计划创建的库名，不删除、重命名或修改其他 Jellyfin 库。

如果计划中的库已经存在：

- 名称、类型、Locations 全部一致 → `REUSABLE`；
- 同名但类型或 Locations 不一致 → `CONFLICT`，停止；
- 不存在 → `MISSING`，只有 `--apply` 才创建。

这样即使用户没有完全删干净旧动画库，也不会被脚本静默覆盖。

## 运行方式

先更新仓库并准备 API key：

```powershell
git pull
$env:JELLYFIN_API_KEY = "<API_KEY>"
```

在用户删除旧动画库之后，先做一次 dry-run：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认没有 `CONFLICT` 后，正式创建：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

完成后再次 dry-run，预期所有计划库都变为 `REUSABLE`。
