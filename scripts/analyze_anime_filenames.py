#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".webm", ".m4v"}
CSV_FIELDS = [
    "Path",
    "FileName",
    "StructureRule",
    "ReleaseGroup",
    "TitleCandidate",
    "RawEpisode",
    "RawEpisodeEnd",
    "ExplicitSeason",
    "ExplicitEpisode",
    "Version",
    "SpecialType",
    "SpecialNumber",
    "TechnicalTags",
    "ParseStatus",
    "Notes",
]


@dataclass
class ParsedContent:
    raw_episode: str = ""
    raw_episode_end: str = ""
    explicit_season: str = ""
    explicit_episode: str = ""
    version: str = ""
    special_type: str = ""
    special_number: str = ""

    @property
    def matched(self) -> bool:
        return bool(self.raw_episode or self.explicit_episode or self.special_type)


class FilenameParser:
    def __init__(self, rules_root: Path):
        self.rules_root = rules_root
        self.structure_rules = self._load("filename_structure.json")["rules"]
        self.episode_patterns = self._compile_list(self._load("fields/episode.json")["patterns"])
        self.special_patterns = self._compile_special(self._load("fields/special_type.json")["types"])
        self.release_group_patterns = self._compile_list(self._load("fields/release_group.json")["patterns"])
        self.title_season_patterns = self._compile_list(self._load("fields/title.json")["season_hints"])
        self.technical_patterns = self._compile_named(self._load("fields/technical_tags.json")["tags"])

    def _load(self, relative: str) -> dict:
        with (self.rules_root / relative).open("r", encoding="utf-8") as handle:
            return json.load(handle)

    @staticmethod
    def _compile_list(items: list[dict]) -> list[tuple[str, re.Pattern[str]]]:
        return [(item["id"], re.compile(item["regex"])) for item in items]

    @staticmethod
    def _compile_special(items: list[dict]) -> list[tuple[str, re.Pattern[str]]]:
        return [(item["type"], re.compile(item["regex"])) for item in items]

    @staticmethod
    def _compile_named(items: list[dict]) -> list[tuple[str, re.Pattern[str]]]:
        return [(item["name"], re.compile(item["regex"])) for item in items]

    def technical_tags(self, text: str) -> list[str]:
        found: list[str] = []
        for name, pattern in self.technical_patterns:
            if pattern.search(text) and name not in found:
                found.append(name)
        return found

    def _is_technical_block(self, text: str) -> bool:
        return bool(self.technical_tags(text))

    def _parse_content(self, text: str) -> ParsedContent:
        value = text.strip().strip("[]").strip()
        for special_type, pattern in self.special_patterns:
            match = pattern.fullmatch(value)
            if match:
                return ParsedContent(
                    special_type=special_type,
                    special_number=(match.groupdict().get("number") or ""),
                )

        for _, pattern in self.episode_patterns:
            match = pattern.fullmatch(value)
            if not match:
                continue
            groups = match.groupdict()
            if groups.get("season"):
                return ParsedContent(
                    explicit_season=groups.get("season") or "",
                    explicit_episode=groups.get("episode") or "",
                    version=groups.get("version") or "",
                )
            return ParsedContent(
                raw_episode=groups.get("episode") or "",
                raw_episode_end=groups.get("episode_end") or "",
                version=groups.get("version") or "",
            )
        return ParsedContent()

    def _extract_release_group(self, text: str) -> tuple[str, str]:
        for _, pattern in self.release_group_patterns:
            match = pattern.match(text)
            if not match:
                continue
            candidate = (match.groupdict().get("release_group") or "").strip()
            if not candidate:
                continue
            if self._is_technical_block(candidate) or self._parse_content(candidate).matched:
                continue
            return candidate, text[match.end():].lstrip()
        return "", text

    def _strip_trailing_technical_blocks(self, text: str) -> tuple[str, list[str]]:
        work = text.rstrip()
        tags: list[str] = []
        while work.endswith("]"):
            start = work.rfind("[")
            if start < 0:
                break
            block = work[start + 1:-1].strip()
            block_tags = self.technical_tags(block)
            if not block_tags:
                break
            for tag in block_tags:
                if tag not in tags:
                    tags.insert(0, tag)
            work = work[:start].rstrip()
        return work, tags

    def _parse_title(self, title: str) -> tuple[str, str]:
        work = title.strip(" -_")
        explicit_season = ""
        for _, pattern in self.title_season_patterns:
            match = pattern.search(work)
            if not match:
                continue
            explicit_season = match.groupdict().get("season") or ""
            work = (work[:match.start()] + " " + work[match.end():]).strip()
            work = re.sub(r"\s{2,}", " ", work).strip(" -_")
            break
        return work, explicit_season

    @staticmethod
    def _leading_bracket_blocks(text: str) -> tuple[list[str], str]:
        blocks: list[str] = []
        pos = 0
        while pos < len(text) and text[pos] == "[":
            end = text.find("]", pos + 1)
            if end < 0:
                break
            blocks.append(text[pos + 1:end])
            pos = end + 1
        return blocks, text[pos:].lstrip()

    def _match_structure(self, core: str, has_group: bool) -> tuple[str, str, str] | None:
        for rule in self.structure_rules:
            kind = rule.get("kind")
            rule_id = rule.get("id", "")

            if kind == "bracket_chain":
                if not has_group or not core.startswith("["):
                    continue
                blocks, _ = self._leading_bracket_blocks(core)
                if len(blocks) >= 2 and self._parse_content(blocks[1]).matched:
                    return rule_id, blocks[0], blocks[1]

            elif kind in {"dash_suffix", "dash_suffix_no_group"}:
                if kind == "dash_suffix" and not has_group:
                    continue
                if kind == "dash_suffix_no_group" and has_group:
                    continue
                dash_positions = [m.start() for m in re.finditer(r"\s+-\s+", core)]
                for pos in reversed(dash_positions):
                    match = re.match(r"\s+-\s+", core[pos:])
                    assert match is not None
                    left = core[:pos].rstrip()
                    right = core[pos + match.end():].strip()
                    if left and self._parse_content(right).matched:
                        return rule_id, left, right

            elif kind == "bracket_suffix":
                if not has_group or not core.endswith("]"):
                    continue
                start = core.rfind("[")
                if start > 0:
                    candidate = core[start + 1:-1]
                    if self._parse_content(candidate).matched:
                        return rule_id, core[:start].rstrip(), candidate

            elif kind == "space_suffix":
                if not has_group:
                    continue
                parts = core.split()
                max_tokens = min(4, len(parts) - 1)
                for count in range(max_tokens, 0, -1):
                    candidate = " ".join(parts[-count:])
                    if self._parse_content(candidate).matched:
                        title = " ".join(parts[:-count]).strip()
                        if title:
                            return rule_id, title, candidate

        return None

    def parse_filename(self, filename: str, path: str = "") -> dict[str, str]:
        stem = Path(filename).stem
        release_group, body = self._extract_release_group(stem)
        core, technical_tags = self._strip_trailing_technical_blocks(body)

        matched = self._match_structure(core, bool(release_group))
        structure_rule = ""
        title_raw = ""
        content_raw = ""
        notes: list[str] = []

        if matched:
            structure_rule, title_raw, content_raw = matched
        else:
            title_raw = core.strip()
            if release_group or title_raw:
                notes.append("未找到可确认的内容编号或特殊类型")

        title, title_season = self._parse_title(title_raw)
        content = self._parse_content(content_raw) if content_raw else ParsedContent()
        explicit_season = content.explicit_season or title_season

        if matched and title and content.matched:
            status = "FULL"
        elif release_group or title or content.matched:
            status = "PARTIAL"
        else:
            status = "UNMATCHED"

        return {
            "Path": path,
            "FileName": filename,
            "StructureRule": structure_rule,
            "ReleaseGroup": release_group,
            "TitleCandidate": title,
            "RawEpisode": content.raw_episode,
            "RawEpisodeEnd": content.raw_episode_end,
            "ExplicitSeason": explicit_season,
            "ExplicitEpisode": content.explicit_episode,
            "Version": content.version,
            "SpecialType": content.special_type,
            "SpecialNumber": content.special_number,
            "TechnicalTags": ";".join(technical_tags),
            "ParseStatus": status,
            "Notes": "；".join(notes),
        }


def iter_video_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*"), key=lambda p: str(p).casefold()):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS:
            yield path


def analyze_directory(root: Path, output: Path, rules_root: Path) -> dict[str, int]:
    if not root.is_dir():
        raise ValueError(f"输入目录不存在：{root}")

    parser = FilenameParser(rules_root)
    counts = {"FULL": 0, "PARTIAL": 0, "UNMATCHED": 0, "TOTAL": 0}
    output.parent.mkdir(parents=True, exist_ok=True)

    with output.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for path in iter_video_files(root):
            row = parser.parse_filename(path.name, str(path))
            writer.writerow(row)
            counts[row["ParseStatus"]] += 1
            counts["TOTAL"] += 1
    return counts


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="递归扫描动画视频文件名并输出结构化 CSV。")
    parser.add_argument("root", help="需要递归扫描的目录")
    parser.add_argument("--output", default="anime-filename-analysis.csv", help="输出 CSV 路径")
    parser.add_argument(
        "--rules-root",
        default=str(Path(__file__).resolve().parents[1] / "rules"),
        help="规则目录；默认使用仓库 rules/",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = Path(args.root)
    output = Path(args.output)
    rules_root = Path(args.rules_root)
    try:
        counts = analyze_directory(root, output, rules_root)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"错误：{exc}")
        return 1

    print(f"扫描视频：{counts['TOTAL']}")
    print(f"完整匹配：{counts['FULL']}")
    print(f"部分匹配：{counts['PARTIAL']}")
    print(f"未匹配：{counts['UNMATCHED']}")
    print(f"输出：{output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
