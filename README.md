# jellyfin-anime-maintenance

用于维护 Jellyfin 动画媒体库的 NFO 纠错规则，主要处理字幕组命名导致的季数、集数和作品识别错误。

## 使用

先预演，不写文件：

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

原始导出通常包含完整媒体库存和本机路径，因此公开仓库只保留规则与脱敏后的诊断结果。
