# Full Canonical View Python 迁移设计

日期：2026-08-14
关联 issue：#4

## 为什么迁移

未完成的 Phase 2 PowerShell 线路已经暴露出多个与 Jellyfin 业务无关的语言/运行时问题。真实 Windows 运行中先出现 .NET regex 转义错误，修复后 full-view dry-run 又只枚举到 634 个视频，而统一 TV audit 的生产基线是 676。

因此不再继续补 Phase 2 PowerShell。已经真实验证、稳定工作的旧 PowerShell 工具继续保留；只有尚未完成的 full canonical view Phase 2 改用 Python。

## 第一阶段目标

先只做只读 inventory + mapping，不实现 `--apply`。

Python 脚本需要：

1. 通过 Jellyfin `/Library/VirtualFolders` 发现 `CollectionType=tvshows` 的生产库位置；
2. 明确排除测试库、`D:\Gekijouban` 和 View 自身；
3. 枚举生产 TV 文件，并识别视频文件；
4. 读取 `jellyfin_tv_nfo_run_log.csv` 中 243 个 correction targets；
5. 生成完整 mapping：243 targets 使用 `SxxEyy -`，其余视频/sidecar 原名透传；
6. 通过 Jellyfin expanded Episode API 取得当前 676 个 Episode 实际路径，直接与 Python 文件枚举做集合差集；
7. 输出缺失/多余路径和按扩展名、library root 的统计，解释 `634 != 676`；
8. 全程不写 View、不创建 hardlink、不修改 Jellyfin、不写 NFO/SQLite。

## 实现形式

使用 Python 标准库，避免引入依赖管理：

- `urllib.request`：Jellyfin GET；
- `json` / `csv`；
- `xml.etree.ElementTree`：后续 NFO 校验；
- `os.scandir`：递归文件枚举；
- `ntpath`：Windows 路径的纯字符串语义。

第一阶段文件保持很少：

```text
scripts/build_jellyfin_full_canonical_view.py
tests/test_full_canonical_view.py
```

不把旧 PowerShell helper 一比一翻译成 Python。

## 676 基线的处理

不把 676 当成“脚本必须硬凑到的数字”。脚本同时得到两套集合：

```text
filesystem_videos
jellyfin_episode_paths
```

然后输出：

```text
jellyfin_only = jellyfin_episode_paths - filesystem_videos
filesystem_only = filesystem_videos - jellyfin_episode_paths
```

只有当差集能够被解释、生产文件全集边界稳定后，才进入第二阶段 Apply。

## 第二阶段边界

后续 Apply 仍沿用已经批准的语义：

- 原始收藏不移动、不重命名；
- 243 confirmed targets 才增加 `SxxEyy -`；
- target 同 basename sidecar 跟随重命名；
- 其他文件完整透传；
- 视频/只读字幕 hardlink，NFO/metadata/未知普通文件 copy；
- manifest-v2、unmanaged collision、rollback 继续保留；
- 33 个 non-target hidden/extras 不自动解释；
- 不做 title/Overview 修复；
- 不自动切 Jellyfin 生产库。

第二阶段必须建立在第一阶段真实 Windows dry-run 已解释 676 基线之后。
