# jellyfin-anime-maintenance

用于维护 Jellyfin 动画媒体库的 NFO 纠错规则，主要处理字幕组命名导致的季数、集数和作品识别错误。

基于本人电脑磁盘上的新番文件，不一定普适，但是希望脚本可能可以帮到遇到同样问题的人~

## 使用

先查看效果：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1
```

确认输出无误后实际写入：

```powershell
.\scripts\jellyfin_tv_nfo_fix.ps1 -Apply
```

脚本默认不会覆盖已经存在的 NFO。

## 目录

- `scripts/`：NFO 生成脚本
- `rules/`：当前动画命名纠错规则
- `reports/`：每次核查的汇总说明
- `samples/`：最小 NFO 示例
- `inputs/raw/`：本地原始 Jellyfin/文件清单导出，不提交到 Git
