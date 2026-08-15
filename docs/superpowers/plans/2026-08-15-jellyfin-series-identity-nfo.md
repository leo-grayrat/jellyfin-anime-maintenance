# Seven Series Identity NFO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 7 部最初自动识别失败的动画，在整理后的 View-v3 Series 目录中安全写入最小 `tvshow.nfo`，固定作品标题与 TVDB/TMDB/IMDb 身份，不触发 Jellyfin 扫描。

**Architecture:** 新脚本内置 7 条明确目标规则（分组目录 + 唯一目录前缀 + 中文标题 + 三套 ID），先完成全量预检，再按 `CREATE / REUSE / CONFLICT` 生成计划。只有整批无冲突时 `--apply` 才原子写入；写入后逐文件回读校验。脚本不调用 Jellyfin API。

**Tech Stack:** Python 3 标准库（`argparse`, `os`, `ntpath`, `tempfile`, `xml.etree.ElementTree`/XML escaping, `unittest`）。

## Global Constraints

- 默认根目录：`D:\Resource\BangumiLink\View-v3`。
- 只处理 7 部指定作品；不处理其他 Series。
- 不修改目录名、视频、字幕、Episode NFO、Jellyfin 数据库或媒体库设置。
- 不触发 Jellyfin 扫描。
- `tvshow.nfo` 只含干净标题和 TVDB/TMDB/IMDb；不含 `displayorder`、简介、季集数量、图片。
- 已有不同内容的 `tvshow.nfo` 一律 `CONFLICT`，不覆盖。
- 任何目标找不到、多匹配、越出 View-v3 或存在冲突时，整批不写。

---

### Task 1: 最小 Series 身份 NFO 写入器

**Files:**
- Create: `scripts/write_jellyfin_series_identity_nfos.py`
- Create: `tests/test_write_jellyfin_series_identity_nfos.py`

**Interfaces:**
- Produces: `SERIES_IDENTITIES`, `render_nfo(entry) -> str`, `build_plan(view_root, entries=SERIES_IDENTITIES) -> list[dict]`, `apply_plan(plan) -> int`, `main(argv=None) -> int`。
- `build_plan` 只枚举指定分组目录的一层子目录，并以 `directory_prefix` 做大小写不敏感的唯一前缀匹配。

- [ ] **Step 1: 写失败测试**

覆盖：
1. XML 只生成 `title + 3 uniqueid`，且无 `displayorder`。
2. 7 条内置身份数据完整且 ID 与已确认值一致。
3. 分组 + 唯一前缀能定位目标目录。
4. 找不到与多匹配会失败。
5. 已有相同 NFO 为 `REUSE`，不同 NFO 为 `CONFLICT`。
6. 任一冲突时 `apply_plan` 拒绝整批写入。
7. 正常 apply 写入后回读一致，并支持第二次运行全部 `REUSE`。

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_write_jellyfin_series_identity_nfos -v`
Expected: FAIL，因为生产脚本尚不存在。

- [ ] **Step 3: 实现最小脚本**

内置目标：

| Group | Prefix | Title | TVDB | TMDB | IMDb |
|---|---|---|---:|---:|---|
| `2017年动画` | `[JYFanSub][Youjo_Senki][01-12+SP]` | `幼女战记` | `315500` | `69346` | `tt6455986` |
| `2023年动画` | `[Nekomoe kissaten&VCB-Studio] THE IDOLM@STER CINDERELLA GIRLS U149` | `偶像大师 灰姑娘女孩 U149` | `424278` | `216391` | `tt26699386` |
| `2025年4月新番` | `[Prejudice-Studio] 前桥魔女 Maebashi Witches` | `前桥魔女` | `454132` | `270602` | `tt35351289` |
| `2025年7月新番` | `[DBD-Raws][克雷瓦提斯-魔兽之王与婴儿与尸之勇者-]` | `克雷瓦提斯-魔兽之王与婴儿与尸之勇者-` | `451793` | `258348` | `tt32991344` |
| `2025年7月新番` | `[Nekomoe kissaten&LoliHouse] Ruri no Houseki` | `瑠璃的宝石` | `454330` | `271649` | `tt37113118` |
| `2025年10月新番` | `[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26` | `藤本树 17-26` | `467641` | `299778` | `tt38491451` |
| `2025年10月新番` | `SPY×FAMILY Season 3` | `SPY×FAMILY` | `405920` | `120089` | `tt13706018` |

XML 固定顺序：`title`, `tvdb`, `tmdb`, `imdb`；UTF-8；结尾换行。写入使用同目录临时文件 + `os.replace`。

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m unittest tests.test_write_jellyfin_series_identity_nfos -v`
Expected: PASS。

- [ ] **Step 5: 运行完整相关测试与语法检查**

Run:
- `python -m unittest tests.test_write_jellyfin_series_identity_nfos tests.test_disable_jellyfin_missing_episode_fetcher -v`
- `python -m py_compile scripts/write_jellyfin_series_identity_nfos.py`

Expected: 全部 PASS / 无输出错误。

- [ ] **Step 6: 提交**

Commit message: `feat: pin seven series identities with minimal nfo`
