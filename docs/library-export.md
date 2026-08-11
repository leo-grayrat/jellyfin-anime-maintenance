# Jellyfin 本地元数据导出

如果想快速检查 Jellyfin 当前识别到的本地元数据，或者把媒体库状态交给 AI 辅助检查，可以用这里的导出脚本生成一个 JSON。

导出内容包括 Series、Season、Episode、Movie，以及路径、Provider ID、标题、简介、日期等主要字段。脚本只读取 Jellyfin API，不会修改媒体文件、NFO 或 Jellyfin 数据库。

## Jellyfin 10.11.x 及以前

使用：

```powershell
.\scripts\export_jellyfin_library_10.ps1 -ApiKey "你的 API Key"
```

这类版本仍可使用旧的 `X-Emby-Token` 请求头。

## Jellyfin 12.0 及以后

使用：

```powershell
.\scripts\export_jellyfin_library_12.ps1 -ApiKey "你的 API Key"
```

Jellyfin 12 默认关闭旧版授权方式，因此旧脚本会返回 HTTP 401。新版脚本使用 `Authorization: MediaBrowser ...` 传递 API Key。

## 可选参数

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

## 注意

- API Key 不要提交到 Git 仓库，也不要公开分享。
- 导出的 JSON 可能包含本地磁盘路径、媒体文件清单、字幕组文件名和 Provider ID。交给 AI 或他人检查前，请确认这些信息可以被分享。
- 如果 API 请求失败，脚本会直接停止，不会继续生成一个看似成功但实际为空的 JSON。