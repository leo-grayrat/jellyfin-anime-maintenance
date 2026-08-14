# Full Canonical View Phase 2 设计

日期：2026-08-14

关联 issue：#4 `NFO 写入后仅部分识别问题得到修正`

## 目标

把当前只覆盖 243 个 correction targets 的 partial canonical view 扩展为可以最终替代生产 TV 根目录的完整 View，同时继续遵守以下边界：

- 不修改、移动、重命名原始收藏；
- 不把 metadata 标题修复塞进结构 builder；
- 只对已经验证过的 243 个 correction targets 使用显式 `SxxEyy` canonical 文件名；
- 其他媒体文件保持原目录结构和原文件名透传，不自动推断或修正其 S/E；
- 不自动处理 33 个 non-target hidden / extras 的语义；
- 不纳入 `D:\Gekijouban`；
- 不纳入测试库；
- 生产切库前必须证明完整覆盖和无不可解释冲突。

当前生产 TV 基线为 676 个实际视频文件，243 个 correction targets 是其中的已确认修正子集。

## 方案

采用“完整镜像 + 仅修 243 targets”的方案。

### 1. correction targets

对 243 个已确认 correction videos：

- 视频在 View 中使用：`SxxEyy - <原文件名>`；
- 同 basename 的 companion files 跟随视频使用相同 `SxxEyy - ` 前缀；
- NFO 继续使用复制，而不是 hardlink；
- 视频使用同盘 NTFS hardlink。

这样保留现有 Phase 1 已验证的身份修正规则，不重新推导 target S/E。

### 2. 其他文件

对 correction targets 之外的生产 TV 文件：

- 保持相对目录不变；
- 保持文件名不变；
- 视频和适合只读透传的普通 companion 文件使用 hardlink；
- 可能被 Jellyfin 或后续工具修改的 metadata 类 sidecar 使用 copy；
- 不为非 target 文件新增 `SxxEyy` 前缀。

这意味着 33 个 non-target hidden、SP、OVA、NCOP/NCED、PV、menu、Bonus 等仍保持现状，不由 Phase 2 自动解释。

## Sidecar 边界

完整 View 不能只镜像视频，否则 correction target 重命名后会破坏外置字幕/NFO 等 basename 关系。

### correction target sidecar

例如：

```text
[Group] Title - 14.mkv
[Group] Title - 14.ass
[Group] Title - 14.nfo
```

在 View 中应成为：

```text
S02E01 - [Group] Title - 14.mkv
S02E01 - [Group] Title - 14.ass
S02E01 - [Group] Title - 14.nfo
```

### sidecar 处理策略

初版采用保守分类：

- 视频：hardlink；
- 外置字幕等明显只读 companion：hardlink；
- NFO：copy；
- artwork / metadata 类 sidecar：copy；
- 无法安全归类但属于生产 TV 根目录的普通文件：默认 copy，而不是丢弃。

Phase 2 的目标是完整 View，而不是只复制“Jellyfin 当前明确使用的文件”。因此未知 sidecar 应优先保留，而不是静默遗漏。

## 与 Phase 1 的关系

冻结当前 `scripts/build_jellyfin_canonical_view.ps1` 的 Phase 1 行为：

- 继续只处理 243 correction targets；
- 不加入全库 pass-through；
- 不加入 metadata title repair；
- 不改变已验证的 manifest / rollback 行为。

Phase 2 使用新的 full-view builder，复用底层安全 helper，但不把全库逻辑硬塞进已验证脚本。

现有 Phase 1 `Logs\manifest.csv` 作为 243 个已存在 canonical video/NFO 的来源证明，在 Phase 2 preflight 中读取和验证；不直接将其改造成全库 manifest。

## Full manifest v2

Phase 2 使用新的 per-file manifest，至少记录：

```text
SourcePath
CanonicalPath
LibraryName
Role
Operation
SourceLength
ExpectedKey
BuildId
Status
```

`Role` 至少区分：

```text
CORRECTION_VIDEO
CORRECTION_SIDECAR
PASSTHROUGH_VIDEO
PASSTHROUGH_FILE
```

`Operation` 至少区分：

```text
HARDLINK
COPY
REUSE
```

目标是让每一个 View 文件都能追溯到唯一 source，并能证明重复运行时是否可安全复用。

## Preflight

任何文件写入前，Phase 2 必须完成全局 preflight。

最低要求：

1. 仅选择 `CollectionType=tvshows` 的生产库；
2. 明确排除测试库；
3. 明确排除 `D:\Gekijouban`；
4. 枚举生产 TV roots 下完整文件集；
5. 证明生产 TV 视频覆盖数量与当前基线一致，当前预期为 676；
6. 证明 243 correction targets 全部存在于生产 source 视频集合；
7. 证明 243 correction NFO 的 `<season>/<episode>` 仍与 correction target 一致；
8. 证明 canonical path 不发生碰撞；
9. 证明 source 与 View 在同一 volume 后才允许 hardlink；
10. 验证现有 Phase 1 243 项的 manifest 来源关系；
11. View 中已有但无法由 manifest 证明来源的冲突文件必须导致 preflight 失败；
12. dry-run 不创建或修改 View / Temp / Logs 内容。

任何一项失败时都不进入 Apply。

## Apply 与回滚

Apply 在完整 preflight 再次通过后执行。

原则：

- 只创建计划中的新 hardlink/copy；
- 已有且可由 manifest 证明来源一致的文件判定为 reusable；
- 不覆盖 unmanaged 文件；
- 每个创建动作记录到 build log；
- 中途失败只回滚本次 build 新创建的 View 文件；
- 不删除旧 build 已管理文件；
- 不修改 source；
- rollback 失败时保留 Temp / failure log，不做猜测性清理。

## Production switch gate

即使 full View 构建成功，也不能自动切生产 Jellyfin library。

切换前至少要证明：

- 676 个生产视频全部在 View 中有唯一对应；
- correction target 243/243 使用正确显式 S/E；
- 所有非 target 视频仍然存在；
- 外置字幕/NFO/重要 sidecar 未因 basename 改名而丢失；
- 没有 unmanaged collision；
- dry-run 二次执行全部表现为可复用；
- 在独立 Jellyfin 测试/验证库中确认 View 不会使正常番剧消失。

之后才人工切换生产 TV library root 到完整 View，并重新执行统一 audit。

## 成功标准

Phase 2 工程完成不等于 issue #4 关闭。完成条件分两层：

### builder 完成

- full builder 有测试覆盖；
- Windows PowerShell 5.1 真实环境 dry-run 通过；
- Apply 构建完整 View；
- 二次 dry-run 幂等；
- source 未被修改；
- manifest v2 能完整追溯所有 View 文件。

### issue #4 完成

在生产切换后重新 audit，确认：

- 正常媒体没有消失；
- 由原路径宽泛解析造成的错误 LocalAlternateVersion 显著消失；
- 243 correction targets 结构稳定；
- 非 target hidden / extras 没有被错误自动修正；
- Season / Episode 结构达到可长期维护状态。

## 明确不做

Phase 2 不负责：

- 修 Episode title / Overview；
- `replaceAllMetadata` 批处理；
- 自动识别 33 个 non-target hidden 的真实语义；
- 重写全部 676 个视频为 SxxEyy；
- 修改 Jellyfin SQLite；
- 修改原始媒体；
- 处理剧场版根目录。
