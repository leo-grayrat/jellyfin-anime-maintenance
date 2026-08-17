#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def _nearest_existing_parent(path: Path) -> Path:
    current = path.parent
    while not current.exists():
        parent = current.parent
        if parent == current:
            break
        current = parent
    return current


def _same_volume(source: Path, target: Path) -> bool:
    source = source.resolve()
    if os.name == "nt":
        source_drive = os.path.splitdrive(str(source))[0].casefold()
        target_drive = os.path.splitdrive(os.path.abspath(str(target)))[0].casefold()
        return bool(source_drive) and source_drive == target_drive

    parent = _nearest_existing_parent(target)
    return source.stat().st_dev == parent.stat().st_dev


def inspect_hardlink(source_text: str, target_text: str) -> str:
    source = Path(source_text)
    target = Path(target_text)

    if not source.is_file():
        raise ValueError(f"源文件不存在或不是普通文件：{source}")

    if target.exists():
        if target.is_file() and os.path.samefile(source, target):
            return "REUSABLE"
        raise ValueError(f"目标路径已经存在且不是同一个硬链接：{target}")

    if not _same_volume(source, target):
        raise ValueError("硬链接只能在同一磁盘/文件系统内创建。")

    return "MISSING"


def create_hardlink(source_text: str, target_text: str) -> str:
    state = inspect_hardlink(source_text, target_text)
    if state == "REUSABLE":
        return state

    source = Path(source_text)
    target = Path(target_text)
    target.parent.mkdir(parents=True, exist_ok=True)
    os.link(source, target)
    if not target.is_file() or not os.path.samefile(source, target):
        raise RuntimeError(f"硬链接创建后校验失败：{target}")
    return "CREATED"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="在你指定的位置建立一个硬链接；不识别作品、不修改 Jellyfin。"
    )
    parser.add_argument("source", help="源文件完整路径")
    parser.add_argument("target", help="目标文件完整路径（包含文件名）")
    parser.add_argument("--apply", action="store_true", help="实际创建；默认仅检查")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        state = inspect_hardlink(args.source, args.target)
        print(f"源文件：{args.source}")
        print(f"目标路径：{args.target}")
        if state == "REUSABLE":
            print("状态：目标已经是同一个硬链接，无需处理。")
            return 0
        if not args.apply:
            print("状态：可以创建。")
            print("模式：试运行（未写入）")
            return 0

        result = create_hardlink(args.source, args.target)
        if result == "CREATED":
            print("状态：硬链接已创建。")
        else:
            print("状态：目标已经是同一个硬链接，无需处理。")
        print("模式：执行")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
