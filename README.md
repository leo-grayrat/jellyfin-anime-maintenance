# jellyfin-anime-maintenance

用于维护 Jellyfin 动画媒体库，处理字幕组命名、季数/集数识别和错误 `LocalAlternateVersion` 合并等问题。

项目最初从 NFO 纠错脚本开始。后续调查确认：NFO 可以修正 Episode 自身的季号/集号，但无法稳定撤销 Jellyfin 在读取 NFO 之前就建立的错误本地多版本关系。因此当前方案进一步加入 **canonical view（规范视图）**：保留原始收藏目录不动，通过同盘 hardlink 让 Jellyfin 看到显式 `SxxEyy - <原文件名>` 的规范输入。

基于本人电脑磁盘上的动画文件，不一定普适，但是希望脚本可能可以帮到遇到同样问题的人~

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

第一版规范视图生成器处理当前 243 个 correction targets：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>"
```

确认 dry-run 后：

```powershell
.\scripts\build_jellyfin_canonical_view.ps1 -ApiKey "<API_KEY>" -Apply
```

详细说明、目录布局、manifest、回滚和当前使用边界见：

```text
docs/canonical-view.md
```

**注意：当前 View 只包含 243 个修正目标，还不能直接替换完整 Jellyfin TV 库，也不应与原始 TV 根目录同时挂进主媒体库。**

如果想快速（让 AI）核查本地元数据，可以查看 `docs/library-export.md` ！

Jellyfin 12 NFO 刷新调查的脚本版本、运行结果和结论存档见 `docs/history/2026-08-11-jellyfin12-nfo-refresh.md`。

关于 `YYYY-MM` 目录参与 Episode 路径解析、错误生成 `LocalAlternateVersion`、显式 `SxxEyy` 文件名规避以及 NFO 路线阶段复盘，见 `docs/history/2026-08-12-jellyfin12-path-parser-and-alternate-version.md`。

## 目录

- `scripts/`：正式 NFO / Jellyfin / canonical view 维护脚本
- `rules/`：当前动画命名纠错规则
- `reports/`：每次核查的汇总说明
- `samples/`：最小 NFO 示例
- `experiments/`：一次性实验脚本与脱敏运行结果，不作为正式工具入口
- `docs/history/`：重要调查过程、版本变化和结论存档
- `inputs/raw/`：本地原始 Jellyfin/文件清单导出，不提交到 Git
