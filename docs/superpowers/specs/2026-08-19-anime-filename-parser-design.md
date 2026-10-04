# 动画文件名解析规则与扫描器设计

## 目标

把 `rules/` 从“早期 NFO 修正规则存放处”改造成可长期复用的**动画字幕组文件名解析规则库**，并新增一个 Python 扫描器：递归扫描指定文件夹中的视频文件，按这些规则拆解文件名并输出 CSV。

本阶段只分析**文件名本身明确表达的信息**，不联网、不查询动画数据库、不读取 Jellyfin 导出结果，也不判断“总第 31 集实际上属于第几季第几集”。

## 设计原则

### 1. 整体结构与字段内部规则分层

不能把“整个文件名怎么排列”和“某个字段内部怎么写”混在同一层。

整体解析先识别类似下面的结构：

```text
[字幕组][标题][内容编号][技术信息...]
[字幕组] 标题 - 内容编号 [技术信息...]
[字幕组] 标题 [内容编号] [技术信息...]
[字幕组] 标题 S01E05 [技术信息...]
标题 - 内容编号 [技术信息...]
```

得到大致结构后，再分别进入：

- 字幕组字段；
- 标题字段；
- 内容编号字段；
- 技术信息字段。

例如 `03v2` 中的 `v2` 是“内容编号”下面的版本信息，不属于整个文件名结构范式。

### 2. 只复述文件名明确表达的事实

例如：

```text
Hyakkano - 31
```

输出：

```text
标题候选：Hyakkano
原始集数：31
```

不额外输出“季数未知”，也不尝试推断它属于哪一季。

只有文件名明确出现 `S03E01`、`S3`、`Season 3` 等信息时，才记录显式季数。

### 3. 特殊内容可以直接分类

如果 `SP`、`OVA`、`OP`、`ED`、`NCOP`、`NCED`、`PV`、`Menu`、`Tokuten`、`特典` 等词出现在正常的内容编号/描述位置，可以直接输出特殊类型，并提取可选编号。

匹配需要遵守边界，不能把 `SPY x FAMILY` 中的 `SP` 错判成特别篇。

更具体的词优先，例如：

```text
NCOP > OP
NCED > ED
```

示例：

```text
[DBD-Raws][Clevatess][Tokuten 03][1080P]...
```

应得到：

```text
特殊类型：TOKUTEN
特殊编号：3
```

### 4. 技术信息第一版只负责隔离，不要求完全拆解

诸如：

```text
[WebRip 1080p HEVC-10bit AAC ASSx2]
```

第一版只需要识别为尾部技术信息，避免 `1080p`、`10bit`、`x265` 等污染标题和集数。

以后可以再拆来源、分辨率、编码、音频、字幕等字段，但不属于本阶段目标。

## `rules/` 新结构

```text
rules/
├─ README.md
├─ filename_structure.json
├─ fields/
│  ├─ episode.json
│  ├─ special_type.json
│  ├─ release_group.json
│  └─ technical_tags.json
└─ legacy/
   └─ jellyfin_tv_nfo_rules.json
```

### `filename_structure.json`

只保存整个文件名的板块排列范式，不放 `v2`、`SP`、`OVA` 等字段内部细节。

### `fields/episode.json`

保存普通内容编号的写法，例如：

- `03`
- `[03]`
- `03v2`
- `[03v2]`
- `01-02`
- `S01E05`

提取字段包括：

- `raw_episode`
- `raw_episode_end`
- `explicit_season`
- `explicit_episode`
- `version`

### `fields/special_type.json`

保存特殊内容标记以及优先顺序，例如：

- `NCOP`
- `NCED`
- `OP`
- `ED`
- `SP`
- `OVA`
- `PV`
- `MENU`
- `TOKUTEN`
- `特典`

并允许提取尾随编号。

### `fields/release_group.json`

保存字幕组字段的常见位置和边界规则。第一版以开头方括号块为主，但不把“第一个方括号永远是字幕组”写成绝对规则。

### `fields/technical_tags.json`

保存用于识别尾部技术信息的常见词，例如：

- WebRip / BDRip / BluRay
- 720p / 1080p / 2160p
- AVC / HEVC / x264 / x265 / AV1
- 8bit / 10bit
- AAC / FLAC / Opus
- ASS / SRT

第一版作用主要是帮助分离标题与尾部技术信息。

### `legacy/jellyfin_tv_nfo_rules.json`

现有 `rules/jellyfin_tv_nfo_rules.json` 移入这里保存，不删除。它已经退出生产用途，但仍提供大量真实字幕组命名样本，可作为新规则库的历史依据。

## Python 扫描器

新增：

```text
scripts/analyze_anime_filenames.py
```

### 输入

接受一个目录：

```powershell
python scripts\analyze_anime_filenames.py "D:\Bangumi"
```

递归扫描以下视频扩展名：

```text
.mkv .mp4 .avi .m2ts .ts .webm .m4v
```

不扫描字幕、NFO、图片等非视频文件。

### 输出

默认在当前目录生成：

```text
anime-filename-analysis.csv
```

允许通过 `--output` 指定路径：

```powershell
python scripts\analyze_anime_filenames.py "D:\Bangumi" `
  --output "D:\Temp\anime-filename-analysis.csv"
```

命令行只打印统计摘要，例如：

```text
扫描视频：720
完整匹配：681
部分匹配：31
未匹配：8
输出：D:\Temp\anime-filename-analysis.csv
```

### CSV 字段

第一版至少包含：

```text
Path
FileName
StructureRule
ReleaseGroup
TitleCandidate
RawEpisode
RawEpisodeEnd
ExplicitSeason
ExplicitEpisode
Version
SpecialType
SpecialNumber
TechnicalTags
ParseStatus
Notes
```

其中：

- `Path`：完整路径；
- `FileName`：原文件名；
- `StructureRule`：命中的整体结构规则；
- `ReleaseGroup`：字幕组；
- `TitleCandidate`：只按文件名得到的标题候选；
- `RawEpisode`：文件名中的原始集数；
- `RawEpisodeEnd`：多集文件的结束集数；
- `ExplicitSeason` / `ExplicitEpisode`：仅在文件名明确写出季集时填写；
- `Version`：例如 `v2`；
- `SpecialType`：例如 `SP`、`OVA`、`NCOP`、`TOKUTEN`；
- `SpecialNumber`：特殊内容编号；
- `TechnicalTags`：识别出的尾部技术信息，多个值可用 `;` 分隔；
- `ParseStatus`：`FULL`、`PARTIAL`、`UNMATCHED`；
- `Notes`：只写解析层面的说明，不写动画数据库知识。

## 解析流程

```text
递归找到视频文件
    ↓
去掉扩展名
    ↓
匹配整体文件名结构
    ↓
拆成字幕组 / 标题 / 内容编号 / 技术信息
    ↓
分别调用字段规则
    ↓
识别普通集数或特殊类型
    ↓
写入 CSV
```

整体结构规则和字段规则相互独立：以后增加一种 `v3`、`PV02`、`NCED_03` 写法，不应该因此新增一种“整个文件名结构”。

## 与现有 Jellyfin 核查工具的关系

本解析器属于更底层的“文件名解释层”。现有 Jellyfin 通用导出和电视动画统一审计仍保持原样。

以后可以把本解析结果与 Jellyfin 导出结果结合，用于判断“Jellyfin 标题是否误取字幕组”“特典是否被当正片”等问题，但**本阶段不实现这一步，也不修改旧导出脚本**。

## 测试范围

新增 Python 测试，至少覆盖：

1. 连续方括号结构；
2. `[字幕组] 标题 - 03`；
3. `[字幕组] 标题 [03]`；
4. `S01E05`；
5. `03v2`；
6. `SP01`；
7. `OVA`；
8. `NCOP` 优先于 `OP`；
9. `SPY x FAMILY` 不误判为 `SP`；
10. `Tokuten 03`；
11. 技术信息不会进入标题候选；
12. 递归目录扫描；
13. CSV 输出字段稳定；
14. 完全无法解析的文件仍写入 CSV，状态为 `UNMATCHED`，不能静默丢弃。

## 非目标

第一版明确不做：

- 不联网；
- 不查询 TMDB / TVDB；
- 不判断总集数属于哪一季；
- 不读取或修改 Jellyfin；
- 不读取现有 Jellyfin 导出 JSON；
- 不修改人工判定清单；
- 不创建硬链接；
- 不自动改名；
- 不要求把所有技术参数完全结构化。
