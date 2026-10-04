# 动画字幕组文件名解析规则

`rules/` 现在用于保存**字幕组文件名的结构化解析知识**。早期 NFO 修正规则不再作为当前主线规则；旧文件移入 `legacy/` 仅作历史样本。

## 分层

解析分成两层，避免把不同层级的规则混在一起：

1. `filename_structure.json`：只描述整个文件名的板块排列，例如 `[字幕组] 标题 - 内容编号 [技术信息]`。
2. `fields/`：分别解析每个字段内部的写法。

当前字段规则包括：

- `release_group.json`：字幕组；
- `title.json`：标题内部明确写出的季数提示；
- `episode.json`：普通集数、范围、`SxxEyy`、`v2`；
- `special_type.json`：SP、OVA、OP/ED、NCOP/NCED、PV、Menu、Tokuten/特典等；
- `technical_tags.json`：分辨率、来源、编码、音频、字幕等尾部技术信息。

例如：

```text
[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26 - 03 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv
```

整体先拆成：字幕组 / 标题 / 内容编号 / 技术信息；然后 `episode.json` 再把 `03` 解释为原始集数 3。

而：

```text
[DBD-Raws][Clevatess][Tokuten 03][1080P][BDRip].mkv
```

会把 `Tokuten 03` 交给 `special_type.json`，得到“特典，第 3 个”。

## 边界

这里只复述**文件名明确表达的事实**。

例如 `Spy x Family - 38` 只输出原始集数 38；是否对应某一季的哪一集，不属于文件名解析规则，需要后续结合人工清单、联网资料或人工核实。

规则也不会因为 `SPY x FAMILY` 中出现字母 `SP` 就判定为特别篇。特殊类型只在正常的内容编号/描述位置进行匹配。

## 扫描器

`scripts/analyze_anime_filenames.py` 接受一个目录，递归扫描视频文件并输出 CSV：

```powershell
python scripts\analyze_anime_filenames.py "D:\Bangumi"
```

默认输出 `anime-filename-analysis.csv`，也可以：

```powershell
python scripts\analyze_anime_filenames.py "D:\Bangumi" `
  --output "D:\Temp\anime-filename-analysis.csv"
```

本阶段不读取 Jellyfin 导出结果。
