#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ntpath
import sys
from collections import Counter
from typing import Sequence

DEFAULT_EXCLUDED_ROOTS = (
    r"C:\bangumi",
    r"D:\Jellyfin-Repro",
    r"D:\Gekijouban",
    r"D:\Resource\BangumiLink\View",
)


def normalize_windows_path(path: str) -> str:
    value = str(path).strip().replace("/", "\\")
    if not value:
        raise ValueError("path must not be empty")
    if value.lower().startswith("\\\\?\\unc\\"):
        value = r"\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return ntpath.normpath(value)


def path_key(path: str) -> str:
    return normalize_windows_path(path).rstrip("\\").casefold()


def path_under_or_equal(path: str, root: str) -> bool:
    p = path_key(path)
    r = path_key(root)
    return p == r or p.startswith(r + "\\")


def classify_root(root: str, excluded_roots: Sequence[str]) -> tuple[str, str]:
    location = normalize_windows_path(root)
    exclusions = [normalize_windows_path(item) for item in excluded_roots]
    for excluded in exclusions:
        if path_under_or_equal(location, excluded):
            return "EXCLUDED", excluded
    for excluded in exclusions:
        if path_under_or_equal(excluded, location):
            return "AMBIGUOUS", excluded
    return "INCLUDED", ""


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only per-root Jellyfin tvshows video count diagnostic")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--exclude-root", action="append", default=[])
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    import build_jellyfin_full_canonical_view as inv

    args = parse_args(argv)
    excluded = list(DEFAULT_EXCLUDED_ROOTS) + list(args.exclude_root)
    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    libraries = inv.flatten_virtual_folders(virtual_folders)

    rows: list[dict] = []
    seen_roots: Counter[str] = Counter()
    for library in libraries:
        name = str(library.get("Name", "")).strip()
        for raw_root in library.get("Locations") or []:
            root = normalize_windows_path(str(raw_root))
            status, reason = classify_root(root, excluded)
            seen_roots[path_key(root)] += 1
            location = {"library_name": name, "library_item_id": str(library.get("ItemId", "")), "root": root}
            files = inv.enumerate_files([location])
            videos = [item for item in files if inv.is_video(item["path"])]
            rows.append({"library": name, "root": root, "status": status, "reason": reason, "videos": len(videos)})

    print("\n=== Jellyfin tvshows Root Scope Diagnostic ===")
    print("Mode: READ ONLY")
    for row in rows:
        suffix = f" :: reason={row['reason']}" if row["reason"] else ""
        print(f"- [{row['status']}] [{row['library']}] {row['root']} :: {row['videos']} videos{suffix}")

    duplicate_roots = [key for key, count in seen_roots.items() if count > 1]
    included = sum(row["videos"] for row in rows if row["status"] == "INCLUDED")
    excluded_count = sum(row["videos"] for row in rows if row["status"] == "EXCLUDED")
    ambiguous = [row for row in rows if row["status"] == "AMBIGUOUS"]
    total = sum(row["videos"] for row in rows)

    print("\nTotals:")
    print(f"tvshows root entries: {len(rows)}")
    print(f"INCLUDED videos:      {included}")
    print(f"EXCLUDED videos:      {excluded_count}")
    print(f"ALL tvshows videos:   {total}")
    print(f"Duplicate root paths: {len(duplicate_roots)}")
    print(f"Ambiguous roots:      {len(ambiguous)}")

    if duplicate_roots:
        print("WARNING: exact root paths occur in more than one tvshows library; ALL total may double-count them.", file=sys.stderr)
    if ambiguous:
        raise RuntimeError("a tvshows location contains an excluded root; scope cannot be classified safely")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
