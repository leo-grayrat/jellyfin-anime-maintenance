# Jellyfin 分组库自动创建与 Series 身份审计设计

## 目标

保留 `View-v3` 已经稳定的文件结构，同时恢复原先按年份/季度拆分的 Jellyfin TV 库体验，并避免手工重复配置 9 个库。

本次只做两件事：

1. 从一个已经配置好 TheTVDB 优先级的模板 TV 库复制完整库设置，按 `View-v3` 一级目录自动创建分组库；
2. 对这些分组库中的 Series 做一次只读身份审计，筛出缺少 TVDB 身份、缺少主海报或明显异常的 Series。

不修改 `View-v3`、原始动画、NFO 或 Jellyfin 数据库文件，不再引入 v4 文件布局。

## 组件一：分组库创建脚本

脚本：`scripts/create_jellyfin_grouped_libraries.py`

### 输入

- Jellyfin server URL，默认 `http://127.0.0.1:8096`；
- API key；
- 模板库名称，由用户显式指定；
- `View-v3` 根目录，默认 `D:\Resource\BangumiLink\View-v3`；
- `--apply` 开关。

### 行为

1. 调用 `/Library/VirtualFolders` 读取当前 TV 库和模板库 `LibraryOptions`；
2. 枚举 `View-v3` 的一级目录，每个一级目录视为一个目标 Jellyfin TV 库：
   - 物理路径始终使用现有一级目录，不重命名 `View-v3`；
   - `YYYY年M月新番` 这种单数字月份只在 Jellyfin 库名中补零为 `YYYY年0M月新番`，因此 `1/4/7` 月显示为 `01/04/07`；
   - `YYYY年10月新番` 等已经是两位数的月份保持不变；
   - `2017年动画` 等非季度目录名保持不变；
3. 复制模板库的完整 `LibraryOptions`，仅替换 `PathInfos` 为当前目标目录；
4. 默认只打印计划，不写 Jellyfin；
5. `--apply` 时通过 `POST /Library/VirtualFolders` 创建缺失库；
6. 已存在“同名且同路径”的库视为已完成并跳过；
7. 模板库作为迁移期间的临时大库，可以暂时与目标分组库使用同一媒体路径；除此之外，已存在“同名但路径不同”或“目标路径还属于其他非模板库”的情况直接报错，不自动覆盖、删除或重命名；
8. 所有库创建完成后只触发一次统一扫描，避免逐库重复扫描。

### 安全边界

- 不删除任何已有库；
- 不修改正式外部库 `C:\bangumi`；
- 不修改任何文件；
- 不重命名 `View-v3` 的现有一级目录；
- 不复制模板库的原始路径，只复制配置；
- 模板必须是 `CollectionType=tvshows`；
- 只对用户显式指定的模板库放宽临时路径重叠，任何其他库占用目标路径仍视为冲突。

## 组件二：Series 身份审计脚本

脚本：`scripts/audit_jellyfin_series_identity.py`

### 输入

- Jellyfin server URL；
- API key；
- `View-v3` 根目录；
- 可选输出 CSV 路径。

### 范围

默认只审计 Jellyfin 中媒体路径位于 `View-v3` 下的 TV 库，不把 `C:\bangumi`、电影库或其他测试目录混进结果。

### 每个 Series 输出

- Jellyfin 库名；
- Series 名称；
- Series 路径；
- 年份；
- TVDB ID；
- TMDB ID；
- IMDb ID；
- 是否有 Primary image；
- Episode 数量；
- 审计状态。

### 状态规则

至少标记：

- `OK`：有 TVDB ID 且有 Primary image；
- `NO_TVDB_ID`：没有 TVDB ID；
- `NO_PRIMARY_IMAGE`：有 TVDB ID 但没有主海报；
- `NO_TVDB_AND_IMAGE`：两者都缺；
- `PATH_OUTSIDE_VIEW_V3`：异常保护状态，正常范围内不应出现。

脚本控制台先给总数和异常清单；CSV 保存完整明细，方便后续只对少量异常 Series 做 Identify/override。

## 复用现有代码

优先复用 `scripts/build_jellyfin_full_canonical_view.py` 中已有的：

- Windows 路径标准化；
- `path_under_or_equal()`；
- Jellyfin GET 鉴权方式。

新增 POST/JSON 请求 helper 时保持同一种 `Authorization` 头格式，不引入第三方依赖。

## 验收标准

### 分组库创建

- Dry-run 能准确列出 `View-v3` 一级目录对应的所有目标库；
- 单数字月份的 Jellyfin 库名按两位数月份显示并参与排序；
- 不带 `--apply` 时 Jellyfin 状态零变化；
- `--apply` 后目标库名称与路径一一对应；
- 新库的 metadata/image provider 优先级、语言等配置与模板库一致；
- 模板库占用同一目标路径时仍可创建分组库；
- 其他非模板库占用目标路径时仍拒绝创建；
- 重跑脚本幂等：已正确创建的库全部跳过；
- 不触碰 `C:\bangumi` 和非目标库。

### Series 审计

- 能枚举所有 `View-v3` 分组库中的 Series；
- 控制台给出 Series 总数、OK 数、异常数；
- CSV 能明确指出无 TVDB ID / 无海报的 Series；
- 审计过程只读，不触发 metadata refresh、Identify 或文件写入。

## 明确不做

- 不自动 Identify Series；
- 不自动修正 TVDB ID；
- 不生成 Episode NFO；
- 不重新构建 canonical View；
- 不删除旧库；
- 不在本次脚本中处理 `C:\bangumi` 的 42 个正式外部视频。
