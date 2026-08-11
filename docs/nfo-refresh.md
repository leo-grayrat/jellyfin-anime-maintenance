# Jellyfin 12 NFO 刷新

Jellyfin 12 已能让 episode NFO 中的 `<season>` 覆盖错误的文件名解析结果，但普通“扫描媒体库”不一定会让已经存在的 Episode 重新读取 NFO。

实测可行流程是：

1. Episode FullRefresh：让 `<season>` / `<episode>` 真正进入 Episode 元数据；
2. Series FullRefresh：按新的季号重新关联 `SeasonId` / `SeasonName`。

脚本 `scripts/refresh_jellyfin_nfo_12.ps1` 会按 `jellyfin_tv_nfo_run_log.csv` 自动完成这两个阶段，并在最后核对季号、集号和 SeasonId。

## 预览

```powershell
.\scripts\refresh_jellyfin_nfo_12.ps1 -ApiKey "你的 API Key"
```

默认只处理运行日志中 `WRITE` 的 Episode，不修改 Jellyfin。

## 实际刷新

```powershell
.\scripts\refresh_jellyfin_nfo_12.ps1 `
    -ApiKey "你的 API Key" `
    -Apply
```

首次修复旧 NFO，或者需要把日志中的 `SKIP_EXISTING` 也重新处理时：

```powershell
.\scripts\refresh_jellyfin_nfo_12.ps1 `
    -ApiKey "你的 API Key" `
    -Apply `
    -IncludeExisting
```

默认不会替换全部标题、简介、图片等现有元数据。如果确认需要重新刮削这些字段，可额外使用 `-ReplaceAllMetadata`。

结果写入：

```text
jellyfin_tv_nfo_refresh_log.csv
```

## 安全范围

- 不修改、移动、重命名或删除视频；
- 不修改已有 NFO；
- 不替换图片；
- 只对目标 Episode 和对应 Series 请求 Jellyfin FullRefresh；
- API Key 和结果日志都不应提交到公开仓库。

该流程针对 Jellyfin 12.x。10.x 的 NFO season 合并行为不同，不建议使用这个脚本。