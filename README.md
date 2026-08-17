# jellyfin-anime-maintenance

## **孩子们我只是想把服务器上动画规整一下怎么就变成了这个样子/(ㄒoㄒ)/\~\~**

> “为了省 NAS，结果最后还是买服务器，白折腾了。”
>
> 不是这样。**我们原本以为瓶颈是“有没有一台 NAS”，实际跑下来才发现，存储根本不是当前瓶颈；真正的瓶颈是媒体整理和公网入口。**
>
> 前一个已经基本解决了。后一个现在也已经定位到一个非常具体的解法。
>
> **恭喜，你不需要买一台贵服务器。**
>
> **你只需要先租一台便宜服务器。**
>
> 确实很有这几天整个项目的精神。

> 不，还没有结束（发出长崎素世的声音）
>
> 因为 **排ISSUE** 的事情还没做呢！

用于维护自己的 Jellyfin 动画媒体库。

当前方案不修改原始动画文件，而是在 ~~建立 NFO 本地元数据纠错脚本 *然而后续调查确认 NFO 可以修正集数自身的季号/集号，但**无法稳定撤销 Jellyfin 在读取 NFO 之前就建立的错误本地多版本关系***~~ 同一磁盘建立**文件名标准化**后的**硬链接**，让 Jellyfin 读取统一的作品、季和集目录结构。

> 基于本人电脑磁盘上的动画文件，不一定普适，但是希望脚本可能可以帮到遇到同样问题的人\~
>
> re：事实上……已经不是几个脚本那么简单了，可能之后会写一个简易的 jellyfin 排坑指南吧
>
> rere：最上面的服务器问题那更是一坨，但是和仓库内容关系不大了

关于网络连接性的排查，参见 [`docs/remote-access-troubleshooting.md`](docs/remote-access-troubleshooting.md)。

## 日常维护

### 新下载动画

下载新一集后先运行：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认没有需要人工判断的新视频后：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

脚本只处理清单中**从未出现过的新文件**。已经记录过的旧文件后来即使被删除，也不会重新创建或阻塞本次更新。

详细说明见 `docs/incremental-hardlink.md`。

### 从清单重建硬链接视图

需要重新建立完整视图时：

```powershell
python scripts\apply_anime_decision_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --d-root "D:\Resource\BangumiLink\View"
```

确认试运行后加 `--apply`。

当前目标目录：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
```

### 重建 Jellyfin 动画库

需要重新建立 Jellyfin 媒体库时：

```powershell
$env:JELLYFIN_API_KEY = "<API_KEY>"

python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认试运行后加 `--apply`。

脚本会按照清单中的“媒体库分组”建库，并自动处理跨 C、D 两个磁盘的媒体目录。

### 导出 Jellyfin 元数据核查

需要完整检查电视动画当前识别状态时：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

如果只想快速（让 AI）核查一般 Jellyfin 元数据，也可以继续使用 `docs/library-export.md` 中的通用导出脚本。

## 目录

- `scripts/`：实际维护脚本，以及早期调查阶段保留下来的工具
- `docs/`：当前使用说明、设计说明和历史记录
- `docs/history/`：项目调查、试验和方案演变存档
- `rules/`：早期 NFO 规则等结构化规则文件
- `reports/`：历史核查结果
- `experiments/`：一次性实验，不作为日常入口
- `samples/`：示例文件
- `tests/`：脚本测试
