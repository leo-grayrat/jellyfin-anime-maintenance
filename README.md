# jellyfin-anime-maintenance

## **孩子们我只是想把服务器上动画规整一下怎么就变成了这个样子/(ㄒoㄒ)/~~**

用于维护 Jellyfin 动画媒体库，处理字幕组命名、季数/集数识别和错误 `LocalAlternateVersion` 合并等问题。

项目最初从 NFO 纠错脚本开始。后续调查确认：NFO 可以修正 Episode 自身的季号/集号，但无法稳定撤销 Jellyfin 在读取 NFO 之前就建立的错误本地多版本关系。因此当前方案进一步加入 **canonical view（规范视图）**：保留原始收藏目录不动，通过同盘 hardlink 让 Jellyfin 看到显式 `SxxEyy - <原文件名>` 的规范输入。

简而言之，这个问题的复杂性已经大大大大大大大大超出了我本来的预期，且至少发现了两个 jellyfin 的 issue 和一堆底层机制 stuff…… 

有人记得主播只是想做一个服务器动画元数据规整脚本的存档吗，然后维护这个仓库就可以直接长期处理服务器动画元数据问题了，结果变成大型工程现场了

> 基于本人电脑磁盘上的动画文件，不一定普适，但是希望脚本可能可以帮到遇到同样问题的人~
>
> re：刚开始时候的美好幻想，现在看来远不是脚本这么简单的事情……

## 使用

### NFO 纠错

先查看效果：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1
```

确认输出无误后实际写入：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1 -Apply
```

脚本默认不会覆盖已经存在的 NFO。

### Jellyfin 规范视图

Phase 1 生成器只处理当前 243 个已经确认的 correction targets：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

确认 dry-run 后：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>" -Apply
```

这一版仍是 partial view，不能单独替换生产 TV 库。

Phase 2 的完整 TV View 已从未完成的 PowerShell 实现切换到 Python。当前 Python 版**只做 read-only inventory + mapping**，专门先查清 production filesystem 与 Jellyfin expanded Episode 的 676 基线差异：

```powershell
python .\scripts\build_jellyfin_full_canonical_view.py `
    --api-key "<API_KEY>"
```

当前没有 `--apply`，不会创建完整 View，也不会修改 Jellyfin/NFO/SQLite。只有实际 dry-run 把文件全集和差集解释清楚后，才继续实现 Full View Apply。

详细设计和当前边界见 `docs/canonical-view.md`。

### 720 文件人工判定视图

当前主线不再从旧 Jellyfin 识别状态反推库存，而是以私有的 720 行人工判定 manifest 为事实源。

先机械建立硬链接视图：

```powershell
python scripts\apply_anime_decision_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --d-root "D:\Resource\BangumiLink\View"
```

加 `--apply` 才真正建立硬链接。当前最终目标根：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
```

文件层闭环后，可以在删除旧动画库后按 manifest 一次性重建最终 Jellyfin 库。脚本直接使用 `LibraryGroup` 作为最终库名，不创建临时前缀库，也不删除旧库：

```powershell
$env:JELLYFIN_API_KEY = "<API_KEY>"
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认 dry-run 没有 `CONFLICT` 后：

```powershell
python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

同一 `LibraryGroup` 如果跨 C/D，脚本会自动把两个目录加入同一个 Jellyfin library；`剧场版` 自动使用 Movie library，其余动画分组使用 TV library。

### TV 动画统一审计导出

在继续修 metadata 之前，可以把 TV 库的结构、Provider 配置、正常/隐藏 Episode、实际视频文件和同名 NFO 一次性导出：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

该脚本只读 Jellyfin 和 TV 文件目录，不处理剧场版，也不会 Refresh、Identify、修改 NFO 或数据库。详细字段和安全边界见 `docs/library-export.md`。

如果只想快速（让 AI）核查一般 Jellyfin 元数据，也可以继续使用 `docs/library-export.md` 中的通用导出脚本。

Jellyfin 12 NFO 刷新调查的脚本版本、运行结果和结论存档见 `docs/history/2026-08-11-jellyfin12-nfo-refresh.md`。

关于 `YYYY-MM` 目录参与 Episode 路径解析、错误生成 `LocalAlternateVersion`、显式 `SxxEyy` 文件名规避以及 NFO 路线阶段复盘，见 `docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md`。

关于 720 文件人工判定、Apply 和自动重建 Jellyfin 库，见：

- `docs/history/2026-08-15-decision-manifest-apply.md`
- `docs/history/2026-08-15-library-rebuild-automation.md`

## 目录

- `scripts/`：正式 NFO / Jellyfin / canonical view / audit 维护脚本
- `rules/`：当前动画命名纠错规则
- `reports/`：每次核查的汇总说明
- `samples/`：最小 NFO 示例
- `experiments/`：一次性实验脚本与脱敏运行结果，不作为正式工具入口
- `docs/history/`：重要调查过程、版本变化和结论存档
- `inputs/raw/`：本地原始 Jellyfin/文件清单导出，不提交到 Git
