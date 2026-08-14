# Jellyfin 本地元数据导出

如果想快速检查 Jellyfin 当前识别到的本地元数据，或者把媒体库状态交给 AI 辅助检查，可以用这里的导出脚本生成 JSON。

仓库现在有两类导出器：

- `export_jellyfin_library_*.ps1`：轻量、通用的 Jellyfin 条目导出；
- `export_jellyfin_tv_audit_12.ps1`：当前 TV 动画维护使用的统一只读审计导出。

## 通用导出

通用导出内容包括 Series、Season、Episode、Movie，以及路径、Provider ID、标题、简介、日期等主要字段。脚本只读取 Jellyfin API，不会修改媒体文件、NFO 或 Jellyfin 数据库。

### Jellyfin 10.11.x 及以前

使用：

```powershell
.\scripts\export_jellyfin_library_10.ps1 -ApiKey "你的 API Key"
```

这类版本仍可使用旧的 `X-Emby-Token` 请求头。

### Jellyfin 12.0 及以后

使用：

```powershell
.\scripts\export_jellyfin_library_12.ps1 -ApiKey "你的 API Key"
```

Jellyfin 12 默认关闭旧版授权方式，因此旧脚本会返回 HTTP 401。新版脚本使用 `Authorization: MediaBrowser ...` 传递 API Key。

### 可选参数

默认服务器地址是：

```text
http://127.0.0.1:8096
```

如需修改：

```powershell
.\scripts\export_jellyfin_library_12.ps1 `
    -ApiKey "你的 API Key" `
    -Server "http://192.168.1.10:8096"
```

默认输出到桌面：

```text
jellyfin-library-export.json
```

也可以指定文件：

```powershell
.\scripts\export_jellyfin_library_12.ps1 `
    -ApiKey "你的 API Key" `
    -Output "D:\Temp\jellyfin-library-export.json"
```

## Jellyfin 12 TV 动画统一审计导出

当目标不只是“看一下当前 metadata”，而是要同时核对季/集结构、错误 `LocalAlternateVersion`、标题/简介/Provider ID、图片状态，以及磁盘上 Jellyfin 可能完全没收进去的文件时，使用：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "你的 API Key"
```

默认输出到桌面：

```text
jellyfin-tv-audit-export.json
```

也支持：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 `
    -ApiKey "你的 API Key" `
    -Server "http://127.0.0.1:8096" `
    -Output "D:\Temp\jellyfin-tv-audit-export.json"
```

### 它导出什么

顶层 schema 当前为 `SchemaVersion = 1`，主要包含：

- `Server`：Jellyfin 版本等基本信息；
- `TvLibraries`：只保留 `CollectionType = tvshows` 的媒体库和完整 `LibraryOptions`，包括 provider 配置；
- `NormalItems`：按 TV 媒体库读取的 Series、Season、Episode；
- `ExpandedEpisodes`：额外使用已经在本服务器验证过的 `VideoTypes=VideoFile` 查询，保留 normally hidden 的 local alternate / owned Episode；
- `FilesystemVideos`：递归枚举 TV library locations 中的视频，并记录文件大小、时间、同名 NFO 是否存在及轻量 NFO 摘要。

`ExpandedEpisodes` 使用全局 expanded Episode 查询后，再通过正常 Series 所属 TV 库以及 TV library root 路径过滤回 TV 范围。这样做是为了保留那些已经没有正常 Season 挂接、但仍然存在于 Jellyfin expanded view 中的异常 Episode。

### NFO 摘要

如果视频旁边存在同名 `.nfo`，审计导出会尽量读取：

- `season`
- `episode`
- `title`
- `plot`
- `uniqueid`，以及常见旧式 `tmdbid` / `tvdbid` / `imdbid`

单个 NFO XML 损坏不会导致整个媒体库导出丢失。该视频仍会出现在 `FilesystemVideos`，错误放在 `NfoReadError`。

### 长路径

TV 文件系统枚举和 NFO 读取使用 Windows Unicode native API / extended path，而不是依赖 Windows PowerShell 5.1 容易触发 `MAX_PATH` 的普通递归枚举。因此像长字幕组目录也不应被静默跳过。

### 安全边界

这个 TV audit exporter：

- 只向 Jellyfin 发 GET 请求；
- 不 Refresh；
- 不 Identify；
- 不 Delete / Merge / Update；
- 不写媒体文件；
- 不写 NFO；
- 不写 Jellyfin 数据库；
- 唯一持久化写入是用户指定的 JSON 文件；
- 序列化后会检查 API Key 字符串没有进入 JSON。

**剧场版媒体库有意不在这份审计中。** 当前阶段仍只处理 TV 动画，剧场版及其中混放的特典/短片等内容以后单独处理。

## 注意

- API Key 不要提交到 Git 仓库，也不要公开分享。
- 导出的 JSON 可能包含本地磁盘路径、媒体文件清单、字幕组文件名和 Provider ID。交给 AI 或他人检查前，请确认这些信息可以被分享。
- 如果 API 请求失败，脚本会直接停止，不会继续生成一个看似成功但实际为空的最终 JSON。
