# 跨作品 canonical hardlink 最终验证设计

## 目标

在《金牌得主》S02E09 之外，再用一个不同作品完成一次最小验证，同时把“显式 `SxxEyy` 命名有效”和“硬链接规范视图可行”两件事一次验证掉。

该实验通过后，不再继续增加单集实验，直接进入第一版 243 个 correction targets 的规范视图生成器。

## 范围

- 只处理 `jellyfin_tv_nfo_run_log.csv` 中已有 correction target。
- 排除《金牌得主》SeriesId `1e343af25a95b525ae23adc50142693a`。
- 自动寻找一个干净的错误 alternate group：
  - group 至少 2 个 media source；
  - group 中每个物理路径都能唯一映射到 correction target；
  - 每个成员的目标 S/E 都不同，不含同集合法多版本；
  - 优先选择不位于 `2026-01` 的 group；
  - 优先选择成员较少的 group，减少实验影响。
- 只从该 group 中选择一个非 owner 成员作为实验对象。

## 实验方法

脚本名：

```text
experiments/jellyfin12-nfo-refresh/14-cross-series-canonical-hardlink-pilot.ps1
```

默认 dry-run。`-Apply` 才会移动文件或创建硬链接。

Apply 流程：

1. 重新验证候选 group 当前仍然是错误 LocalAlternateVersion/owned 状态，并记录 owner media-source count。
2. 将目标视频和同 basename NFO 临时移动到同盘、Jellyfin 库外 staging 目录。
3. 等待 Jellyfin 实时监控删除旧 target，要求：
   - owner media-source count 减 1；
   - 原 target 在 expanded query 中消失。
4. 在原作品目录创建：

```text
SxxEyy - <原字幕组文件名>.<ext>
```

   其中视频不是复制或移动，而是使用 `New-Item -ItemType HardLink` 指向 staging 中的原视频；NFO 复制为同 basename，并保持原内容不变。
5. 等待 Jellyfin 导入 canonical hardlink，要求稳定状态：
   - canonical target normal query 可见；
   - expanded query 可见；
   - current key 等于 correction target 的 `SxxEyy`；
   - media-source count = 1；
   - SeriesId 与原作品一致；
   - 通过 `/Shows/{SeriesId}/Episodes` 可见；
   - 原 owner 不包含 canonical path，source count 仍保持“减 1”状态。
6. 将实验结果打印为：
   - `CANONICAL HARDLINK STAYS INDEPENDENT`
   - `CANONICAL HARDLINK RE-MERGED`
   - `PARTIAL / OTHER STATE`
7. 无论成功或失败，实验结束时默认恢复原始服务器状态：
   - 删除 canonical NFO 与 canonical hardlink；
   - 等 Jellyfin 删除 canonical item；
   - 将 staging 中原 NFO 与原视频移动回原始路径；
   - 等待 Jellyfin 恢复原 group；
   - 最终确认原路径存在、staging 为空。

这样第二个实验不会长期改名用户的收藏文件，也不会留下额外硬链接。

## 安全边界

- 不写 SQLite。
- 不调用 metadata FullRefresh。
- 不调用 `/Videos/{id}/AlternateSources`。
- 不修改 NFO XML 内容。
- 不处理 correction target 之外的未知成员。
- 不选择包含同一 S/E 多个成员的 group。
- staging 必须与视频位于同一盘，保证硬链接可建立。
- canonical 文件名若已存在则立即停止。
- 任一中间验证不满足预期时停止扩大操作，并优先恢复原文件路径。

## 成功标准

只有同时满足以下条件才认为第二个样本通过：

```text
canonical normal visible = true
canonical expanded visible = true
canonical key = expected SxxEyy
canonical media-source count = 1
canonical SeriesId = original SeriesId
visible through Series = true
owner does not contain canonical path
```

并且脚本最后成功恢复实验前文件布局。

若该跨作品硬链接实验成功，则后续正式方向固定为：

- 第一版只覆盖 243 个 correction targets；
- 原始媒体文件不改名、不移动；
- 为 Jellyfin 生成独立规范视图；
- 规范视图视频优先使用同盘硬链接；
- Jellyfin 侧文件名统一显式 `SxxEyy - <原文件名>`；
- NFO 同 basename 复制到规范视图；
- 继续保留合法同集多版本与未知成员的保护逻辑。