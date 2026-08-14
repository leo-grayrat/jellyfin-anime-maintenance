#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ntpath
import sys
from collections import Counter
from typing import Sequence

TEST_ROOTS = (
    r"D:\Jellyfin-Repro",
)
EXTERNAL_PRODUCTION_ROOTS = (
    r"C:\bangumi",
)
OUT_OF_VIEW_ROOTS = (
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


def _matches_any(root: str, candidates: Sequence[str]) -> str:
    for candidate in candidates:
        if path_under_or_equal(root, candidate):
            return normalize_windows_path(candidate)
    return ""


def classify_root(root: str) -> tuple[str, str]:
    location = normalize_windows_path(root)
    reason = _matches_any(location, TEST_ROOTS)
    if reason:
        return "TEST", reason
    reason = _matches_any(location, EXTERNAL_PRODUCTION_ROOTS)
    if reason:
        return "EXTERNAL_PRODUCTION", reason
    reason = _matches_any(location, OUT_OF_VIEW_ROOTS)
    if reason:
        return "OUT_OF_VIEW", reason

    for candidate in TEST_ROOTS + EXTERNAL_PRODUCTION_ROOTS + OUT_OF_VIEW_ROOTS:
        if path_under_or_equal(candidate, location):
            return "AMBIGUOUS", normalize_windows_path(candidate)
    return "VIEW_SCOPE", ""


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only per-root Jellyfin tvshows scope diagnostic")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    import build_jellyfin_full_canonical_view as inv

    args = parse_args(argv)
    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    libraries = inv.flatten_virtual_folders(virtual_folders)

    rows: list[dict] = []
    seen_roots: Counter[str] = Counter()
    for library in libraries:
        name = str(library.get("Name", "")).strip()
        for raw_root in library.get("Locations") or []:
            root = normalize_windows_path(str(raw_root))
            status, reason = classify_root(root)
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
    view_scope = sum(row["videos"] for row in rows if row["status"] == "VIEW_SCOPE")
    external = sum(row["videos"] for row in rows if row["status"] == "EXTERNAL_PRODUCTION")
    test = sum(row["videos"] for row in rows if row["status"] == "TEST")
    out_of_view = sum(row["videos"] for row in rows if row["status"] == "OUT_OF_VIEW")
    production = view_scope + external
    all_tvshows = sum(row["videos"] for row in rows)
    ambiguous = [row for row in rows if row["status"] == "AMBIGUOUS"]

    print("\nTotals:")
    print(f"tvshows root entries:       {len(rows)}")
    print(f"VIEW_SCOPE videos:          {view_scope}")
    print(f"EXTERNAL_PRODUCTION videos: {external}")
    print(f"PRODUCTION TV videos:       {production}")
    print(f"TEST videos:                {test}")
    print(f"OUT_OF_VIEW videos:         {out_of_view}")
    print(f"ALL tvshows videos:         {all_tvshows}")
    print(f"Duplicate root paths:       {len(duplicate_roots)}")
    print(f"Ambiguous roots:            {len(ambiguous)}")

    if duplicate_roots:
        print("WARNING: exact root paths occur in more than one tvshows library; ALL total may double-count them.", file=sys.stderr)
    if ambiguous:
        raise RuntimeError("a tvshows location overlaps a classified root boundary; scope cannot be classified safely")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
