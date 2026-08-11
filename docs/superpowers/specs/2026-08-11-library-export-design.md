# Jellyfin 媒体库导出工具设计

## 目标

提供两个只读 PowerShell 脚本，把 Jellyfin 的媒体库结构、路径、Provider ID 和主要元数据导出为 JSON，方便人工检查或交给 AI 快速核查本地元数据问题。

## 版本区分

- Jellyfin 10.11.x 及更早版本：使用兼容旧认证头 `X-Emby-Token` 的脚本。
- Jellyfin 12.0（含当前 Unstable）及之后：使用 `Authorization: MediaBrowser ... Token=...` 的脚本。Jellyfin 12 默认关闭 legacy authorization，因此旧脚本会返回 HTTP 401。

## 文件

- `scripts/export_jellyfin_library_10.ps1`
- `scripts/export_jellyfin_library_12.ps1`
- `docs/library-export.md`
- `README.md` 增加一句入口说明。

两个脚本均通过 `-ApiKey` 传入密钥，可选 `-Server` 和 `-Output`，不在仓库中保存真实 API Key；调用失败时立即停止，避免生成看似成功的空 JSON。

## 输出

JSON 保留 `ExportedAt`、`Libraries` 和 `Items`。Items 导出 Series、Season、Episode、Movie，并包含 Path、ProviderIds、Overview、PremiereDate、DateCreated、OriginalTitle、SortName 等字段。

## 范围

脚本只调用 Jellyfin 只读 API，不修改媒体文件、NFO、Jellyfin 数据库或服务器配置。README 只增加用户指定的一句文档入口，不改其他内容。
