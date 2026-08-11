# Jellyfin 12 Refresh Experiment Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 2026-08-11 Jellyfin 12 NFO 刷新调查中的脚本版本、运行结果、已证实结论和被推翻假设保存到仓库，避免以后依赖聊天记忆。

**Architecture:** 正式工具继续保留在 `scripts/`。一次性实验脚本和脱敏后的运行结果放进 `experiments/jellyfin12-nfo-refresh/`；完整调查时间线放进 `docs/history/`。已经进入 Git 历史的批量脚本版本不重复复制整份源码，而用不可变 commit SHA 索引；未提交过的一次性脚本保存完整副本。

**Tech Stack:** Markdown、PowerShell、Git/GitHub。

## Global Constraints

- 不提交 API Key。
- 不提交本机绝对媒体路径；结果文件使用 `<MEDIA_ROOT>` 等占位符或直接省略路径。
- `experiments/` 明确标记为历史实验，不作为当前推荐入口。
- 对错误假设和失败结果原样记录，不事后改写。
- 当前正式脚本仍是 `scripts/refresh_jellyfin_nfo_12.ps1`。

---

### Task 1: 建立实验索引与调查时间线

**Files:**
- Create: `experiments/jellyfin12-nfo-refresh/README.md`
- Create: `docs/history/2026-08-11-jellyfin12-nfo-refresh.md`

**Interfaces:**
- Consumes: Git commit `c7c8042`, `bc478d9`, `d9ae8ff` 和本轮实际运行结果。
- Produces: 后续可从一处定位每个脚本、每次运行和当前结论的索引。

- [ ] **Step 1:** 写明每个阶段的目标、脚本来源、运行结果和结论。
- [ ] **Step 2:** 明确区分“已证实”“推断”“已推翻”“待验证”。
- [ ] **Step 3:** 检查文档中不存在 API Key 和本机绝对路径。
- [ ] **Step 4:** 提交文档。

### Task 2: 保存未进入 Git 历史的一次性实验脚本

**Files:**
- Create: `experiments/jellyfin12-nfo-refresh/01-single-episode-refresh-broken.ps1`
- Create: `experiments/jellyfin12-nfo-refresh/02-single-episode-refresh.ps1`
- Create: `experiments/jellyfin12-nfo-refresh/03-series-relink.ps1`
- Create: `experiments/jellyfin12-nfo-refresh/04-fate-filesystem-refresh.ps1`
- Create: `experiments/jellyfin12-nfo-refresh/05-fate-readonly-diagnosis.ps1`

**Interfaces:**
- Consumes: 本次对话中实际交付给用户运行的完整脚本。
- Produces: 可复查的历史脚本副本；05 标记为尚未运行。

- [ ] **Step 1:** 保存五个完整脚本并统一用 `PASTE_API_KEY_HERE` 占位。
- [ ] **Step 2:** 在文件头注明历史用途、状态和是否实际运行。
- [ ] **Step 3:** 不改写脚本的关键实验逻辑。
- [ ] **Step 4:** 提交脚本。

### Task 3: 保存脱敏后的运行结果

**Files:**
- Create: `experiments/jellyfin12-nfo-refresh/results/01-single-episode-400.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/02-single-episode-success.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/03-series-relink-success.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/04-batch-dryrun-missing-38.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/05-batch-dryrun-all-found.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/06-batch-apply-230-of-243.txt`
- Create: `experiments/jellyfin12-nfo-refresh/results/07-fate-filesystem-refresh-failed.txt`

**Interfaces:**
- Consumes: 用户实际 PowerShell 输出与 CSV 统计。
- Produces: 可公开的实验结果，不包含本机绝对路径。

- [ ] **Step 1:** 保存关键控制台输出和统计数字。
- [ ] **Step 2:** 对本地路径做脱敏但保留 ItemId/SeriesId 等排错所需元数据。
- [ ] **Step 3:** 在每个结果文件顶部标明对应脚本/commit。
- [ ] **Step 4:** 提交结果。

### Task 4: 验证归档可导航且不泄露本地信息

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1-3 的新目录。
- Produces: 仓库首页到调查存档的入口。

- [ ] **Step 1:** 在目录说明中加入 `experiments/` 和 `docs/history/`。
- [ ] **Step 2:** 搜索新文件中是否存在 `D:\\Bangumi`、API Key 实值或其他本机绝对路径。
- [ ] **Step 3:** 确认批量脚本版本索引的 SHA 与 Git 历史一致。
- [ ] **Step 4:** 提交 README 更新。