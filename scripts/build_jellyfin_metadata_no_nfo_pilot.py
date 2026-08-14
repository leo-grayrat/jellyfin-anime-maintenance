#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ntpath
import os
import sys
from dataclasses import dataclass
from typing import Sequence


DEFAULT_MANIFEST = r"D:\Resource\BangumiLink\Logs\full-manifest-v3.csv"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3\2026年1月新番"
DEFAULT_PILOT_ROOT = r"D:\Resource\BangumiLink\MetadataPilot-v3\2026年1月新番"


@dataclass(frozen=True)
class Target:
    label: str
    series_folder: str
    key: str


TARGETS = (
    Target(
        "Frieren S02E02 (current Overview present, Name fallback)",
        "葬送のフリーレン 第2期 (2026) [tmdbid-209867]",
        "S02E02",
    ),
    Target(
        "Frieren S02E06 (current Overview missing, Name fallback)",
        "葬送のフリーレン 第2期 (2026) [tmdbid-209867]",
        "S02E06",
    ),
    Target(
        "Oshi no Ko S03E02 (current Overview present, Name fallback)",
        "【推しの子】 第3期 (2026) [tmdbid-203737]",
        "S03E02",
    ),
    Target(
        "Oshi no Ko S03E07 (current Overview missing, Name fallback)",
        "【推しの子】 第3期 (2026) [tmdbid-203737]",
        "S03E07",
    ),
)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build a four-episode, no-NFO Jellyfin metadata pilot from the validated v3 View. "
            "Default is read-only; --apply creates hardlinks only under MetadataPilot-v3."
        )
    )
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--pilot-root", default=DEFAULT_PILOT_ROOT)
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def path_key(path: str) -> str:
    return ntpath.normcase(ntpath.normpath(path.strip()))


def relative_under(path: str, root: str) -> str:
    rel = ntpath.relpath(path, root)
    if rel == ntpath.pardir or rel.startswith(ntpath.pardir + ntpath.sep):
        raise ValueError(f"path is outside expected v3 validation root: {path}")
    return rel


def load_manifest(path: str) -> list[dict[str, str]]:
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"manifest is empty: {path}")
    return rows


def select_plan(
    rows: list[dict[str, str]], view_root: str, pilot_root: str
) -> list[dict[str, str]]:
    plan: list[dict[str, str]] = []
    for target in TARGETS:
        matches: list[dict[str, str]] = []
        series_prefix = path_key(ntpath.join(view_root, target.series_folder)) + ntpath.sep
        for row in rows:
            if row.get("Role") != "CORRECTION_VIDEO":
                continue
            if row.get("ExpectedKey") != target.key:
                continue
            canonical = row.get("CanonicalPath", "")
            if not canonical:
                continue
            if path_key(canonical).startswith(series_prefix):
                matches.append(row)

        if len(matches) != 1:
            raise ValueError(
                f"expected exactly one manifest row for {target.label}, found {len(matches)}"
            )

        source = matches[0]["CanonicalPath"]
        rel = relative_under(source, view_root)
        destination = ntpath.join(pilot_root, rel)
        plan.append(
            {
                "label": target.label,
                "source": source,
                "destination": destination,
            }
        )

    destinations = [path_key(row["destination"]) for row in plan]
    if len(destinations) != len(set(destinations)):
        raise ValueError("pilot destination collision detected")
    return plan


def classify_existing(source: str, destination: str) -> str:
    if not os.path.exists(destination):
        return "MISSING"
    if not os.path.isfile(destination):
        return "CONFLICT"
    try:
        if os.path.samefile(source, destination):
            return "REUSABLE"
    except OSError:
        pass
    return "CONFLICT"


def print_plan(plan: list[dict[str, str]]) -> list[str]:
    states: list[str] = []
    print("\n=== Jellyfin v3 No-NFO Metadata Pilot ===")
    print("Purpose: isolate whether sparse Episode NFO affects remote Name/Overview lookup")
    print("Files copied: 0")
    print("NFO files:    0")
    print("Video links:  4")
    print("")
    for index, row in enumerate(plan, 1):
        state = classify_existing(row["source"], row["destination"])
        states.append(state)
        print(f"[{index}] {row['label']}")
        print(f"    {state}: {row['destination']}")
    print("")
    print(f"Reusable:  {states.count('REUSABLE')}")
    print(f"To create: {states.count('MISSING')}")
    print(f"Conflicts: {states.count('CONFLICT')}")
    return states


def apply_plan(plan: list[dict[str, str]]) -> tuple[int, int]:
    states = [classify_existing(row["source"], row["destination"]) for row in plan]
    if "CONFLICT" in states:
        raise ValueError("pilot root contains a conflicting destination; refusing to modify it")

    created = 0
    reused = 0
    created_paths: list[str] = []
    try:
        for row, state in zip(plan, states):
            if state == "REUSABLE":
                reused += 1
                continue
            destination = row["destination"]
            os.makedirs(ntpath.dirname(destination), exist_ok=True)
            os.link(row["source"], destination)
            created_paths.append(destination)
            created += 1
    except Exception:
        for path in reversed(created_paths):
            try:
                os.remove(path)
            except OSError:
                pass
        raise
    return created, reused


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    manifest = ntpath.normpath(args.manifest)
    view_root = ntpath.normpath(args.view_root)
    pilot_root = ntpath.normpath(args.pilot_root)

    if path_key(view_root) == path_key(pilot_root):
        raise ValueError("pilot root must not be the validated v3 View root")

    rows = load_manifest(manifest)
    plan = select_plan(rows, view_root, pilot_root)
    states = print_plan(plan)
    if "CONFLICT" in states:
        raise ValueError("conflicts detected; no files were written")

    if not args.apply:
        print("DRY RUN finished. No files were written.")
        print(f"Pilot library root after --apply: {pilot_root}")
        return 0

    created, reused = apply_plan(plan)
    print("=== No-NFO metadata pilot build complete ===")
    print(f"Created hardlinks: {created}")
    print(f"Reused hardlinks:  {reused}")
    print(f"Pilot root:        {pilot_root}")
    print("No NFO, subtitle, image, or other sidecar was copied.")
    print("Validated View-v3 and original media paths were not modified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
