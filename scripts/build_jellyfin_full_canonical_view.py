#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import ntpath
import os
import stat
import sys
import urllib.parse
import urllib.request
from collections import Counter
from typing import Iterable, Sequence

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".m4v", ".avi", ".ts", ".webm"}
DEFAULT_EXCLUDED_ROOTS = (
    r"C:\bangumi",
    r"D:\Jellyfin-Repro",
    r"D:\Gekijouban",
    r"D:\Resource\BangumiLink\View",
)


def normalize_windows_path(path: str) -> str:
    if path is None:
        raise ValueError("path must not be None")
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


def is_video(path: str) -> bool:
    return ntpath.splitext(path)[1].casefold() in VIDEO_EXTENSIONS


def episode_key(season: int, episode: int) -> str:
    return f"S{season:02d}E{episode:02d}"


def load_targets(csv_path: str, expected_count: int = 243) -> list[dict]:
    by_path: dict[str, dict] = {}
    with open(csv_path, "r", encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("RuleId", "") == "series-nfo":
                continue
            if row.get("Action", "") != "WRITE":
                continue
            video_path = (row.get("VideoPath") or "").strip()
            season_text = (row.get("Season") or "").strip()
            episode_text = (row.get("Episode") or "").strip()
            if not video_path or not season_text or not episode_text:
                continue
            season = int(season_text)
            episode = int(episode_text)
            normalized = normalize_windows_path(video_path)
            key = path_key(normalized)
            target = {
                "work": row.get("Work", ""),
                "rule_id": row.get("RuleId", ""),
                "video_path": normalized,
                "path_key": key,
                "season": season,
                "episode": episode,
                "expected_key": episode_key(season, episode),
            }
            previous = by_path.get(key)
            if previous:
                if (previous["season"], previous["episode"]) != (season, episode):
                    raise ValueError(f"conflicting correction targets for path: {normalized}")
                continue
            by_path[key] = target
    targets = sorted(by_path.values(), key=lambda x: x["video_path"].casefold())
    if expected_count >= 0 and len(targets) != expected_count:
        raise ValueError(f"expected exactly {expected_count} correction targets, found {len(targets)}")
    return targets


def file_stem(path: str) -> str:
    return ntpath.splitext(ntpath.basename(normalize_windows_path(path)))[0]


def find_sidecar_target(path: str, targets: Sequence[dict]) -> dict | None:
    if is_video(path):
        return None
    directory = path_key(ntpath.dirname(normalize_windows_path(path)))
    stem = file_stem(path).casefold()
    matches = [
        t
        for t in targets
        if path_key(ntpath.dirname(t["video_path"])) == directory
        and file_stem(t["video_path"]).casefold() == stem
    ]
    if len(matches) > 1:
        raise ValueError(f"sidecar matches multiple correction targets: {path}")
    return matches[0] if matches else None


def build_mapping(files: Sequence[dict], targets: Sequence[dict], view_root: str) -> list[dict]:
    target_index = {t["path_key"]: t for t in targets}
    source_index: dict[str, dict] = {}
    for source in files:
        key = path_key(source["path"])
        if key in source_index:
            raise ValueError(f"duplicate source path: {source['path']}")
        source_index[key] = source
    missing_targets = [t["video_path"] for t in targets if t["path_key"] not in source_index]
    if missing_targets:
        raise ValueError(f"correction target absent from inventory: {missing_targets[0]}")

    owners: dict[str, str] = {}
    result: list[dict] = []
    for source in sorted(files, key=lambda x: path_key(x["path"])):
        source_path = normalize_windows_path(source["path"])
        source_key = path_key(source_path)
        target = target_index.get(source_key)
        expected = ""
        if target:
            role = "CORRECTION_VIDEO"
            expected = target["expected_key"]
        elif not is_video(source_path):
            target = find_sidecar_target(source_path, targets)
            if target:
                role = "CORRECTION_SIDECAR"
                expected = target["expected_key"]
            else:
                role = "PASSTHROUGH_FILE"
        else:
            role = "PASSTHROUGH_VIDEO"

        library_root = normalize_windows_path(source["library_root"])
        if not path_under_or_equal(source_path, library_root) or path_key(source_path) == path_key(library_root):
            raise ValueError(f"source outside library root: source={source_path} root={library_root}")
        relative = source_path[len(library_root.rstrip('\\')) + 1 :]
        relative_dir, filename = ntpath.split(relative)
        if expected:
            filename = f"{expected} - {filename}"
        canonical = ntpath.join(normalize_windows_path(view_root), source["library_name"], relative_dir, filename)
        canonical_key = path_key(canonical)
        if canonical_key in owners:
            raise ValueError(
                f"canonical path collision: {canonical} :: source1={owners[canonical_key]} source2={source_path}"
            )
        owners[canonical_key] = source_path
        result.append(
            {
                "source_path": source_path,
                "canonical_path": normalize_windows_path(canonical),
                "library_name": source["library_name"],
                "library_root": library_root,
                "role": role,
                "expected_key": expected,
            }
        )
    return result


def flatten_virtual_folders(value) -> list[dict]:
    result: list[dict] = []
    queue = [value]
    while queue:
        current = queue.pop(0)
        if current is None:
            continue
        if isinstance(current, dict) and {"Name", "CollectionType", "Locations"}.issubset(current):
            if current.get("CollectionType") == "tvshows":
                result.append(current)
            continue
        if isinstance(current, dict) and "value" in current:
            queue.append(current["value"])
            continue
        if isinstance(current, (list, tuple)):
            queue.extend(current)
            continue
        raise ValueError("unexpected Jellyfin virtual-folder response shape")
    return sorted(result, key=lambda x: str(x.get("Name", "")).casefold())


def select_production_locations(virtual_folders, excluded_roots: Sequence[str]) -> list[dict]:
    exclusions = [normalize_windows_path(x) for x in excluded_roots]
    result: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for library in flatten_virtual_folders(virtual_folders):
        name = str(library.get("Name", "")).strip()
        for raw_location in library.get("Locations") or []:
            location = normalize_windows_path(str(raw_location))
            if any(path_under_or_equal(location, excluded) for excluded in exclusions):
                continue
            containing = [excluded for excluded in exclusions if path_under_or_equal(excluded, location)]
            if containing:
                raise ValueError(
                    f"tvshows location contains an excluded root: location={location} excluded={containing[0]}"
                )
            key = (name.casefold(), path_key(location))
            if key in seen:
                continue
            seen.add(key)
            result.append({"library_name": name, "library_item_id": str(library.get("ItemId", "")), "root": location})
    result.sort(key=lambda x: (x["library_name"].casefold(), path_key(x["root"])))
    return result


def _to_extended_windows_path(path: str) -> str:
    normalized = normalize_windows_path(path)
    if normalized.startswith("\\\\"):
        return "\\\\?\\UNC\\" + normalized[2:]
    return "\\\\?\\" + normalized


def enumerate_files(locations: Sequence[dict]) -> list[dict]:
    result: list[dict] = []
    seen: set[str] = set()
    for location in locations:
        logical_root = normalize_windows_path(location["root"])
        physical_root = _to_extended_windows_path(logical_root) if os.name == "nt" else logical_root
        stack: list[tuple[str, str]] = [(physical_root, logical_root)]
        while stack:
            physical_dir, logical_dir = stack.pop()
            with os.scandir(physical_dir) as entries:
                for entry in entries:
                    logical_path = ntpath.join(logical_dir, entry.name)
                    if entry.is_symlink():
                        continue
                    entry_stat = entry.stat(follow_symlinks=False)
                    if os.name == "nt":
                        attributes = getattr(entry_stat, "st_file_attributes", 0)
                        if attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
                            continue
                    if entry.is_dir(follow_symlinks=False):
                        stack.append((entry.path, logical_path))
                    elif entry.is_file(follow_symlinks=False):
                        key = path_key(logical_path)
                        if key in seen:
                            raise ValueError(f"duplicate file across selected roots: {logical_path}")
                        seen.add(key)
                        result.append(
                            {
                                "library_name": location["library_name"],
                                "library_root": logical_root,
                                "path": normalize_windows_path(logical_path),
                                "size": entry_stat.st_size,
                            }
                        )
    return sorted(result, key=lambda x: path_key(x["path"]))


def jellyfin_get(server: str, api_key: str, path: str, query: dict | None = None):
    base = server.rstrip("/") + "/" + path.lstrip("/")
    if query:
        base += "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(
        base,
        headers={
            "Authorization": (
                'MediaBrowser Client="full-canonical-view-python", Device="Python", '
                f'DeviceId="full-canonical-view-python", Version="1.0", Token="{api_key}"'
            )
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def get_expanded_episode_paths(server: str, api_key: str, locations: Sequence[dict]) -> list[str]:
    start = 0
    limit = 500
    all_paths: list[str] = []
    while True:
        response = jellyfin_get(
            server,
            api_key,
            "/Items",
            {
                "Recursive": "true",
                "StartIndex": start,
                "Limit": limit,
                "IncludeItemTypes": "Episode",
                "Fields": "Path,SeriesId",
                "EnableImages": "false",
                "EnableUserData": "false",
                "VideoTypes": "VideoFile",
            },
        )
        items = response.get("Items") or []
        for item in items:
            path = str(item.get("Path") or "").strip()
            if not path:
                continue
            if any(path_under_or_equal(path, loc["root"]) for loc in locations):
                all_paths.append(normalize_windows_path(path))
        start += len(items)
        total = int(response.get("TotalRecordCount") or 0)
        if not items or start >= total:
            break
    return sorted({path_key(p): p for p in all_paths}.values(), key=path_key)


def diff_paths(filesystem_paths: Iterable[str], jellyfin_paths: Iterable[str]) -> tuple[list[str], list[str]]:
    fs = {path_key(p): normalize_windows_path(p) for p in filesystem_paths}
    jf = {path_key(p): normalize_windows_path(p) for p in jellyfin_paths}
    jellyfin_only = [jf[k] for k in sorted(jf.keys() - fs.keys())]
    filesystem_only = [fs[k] for k in sorted(fs.keys() - jf.keys())]
    return jellyfin_only, filesystem_only


def print_inventory_report(locations: Sequence[dict], files: Sequence[dict], episode_paths: Sequence[str]) -> None:
    videos = [f for f in files if is_video(f["path"])]
    print("\n=== Python Full Canonical View Inventory ===")
    print("Mode: READ ONLY")
    print("\nSelected TV roots:")
    for loc in locations:
        count = sum(1 for f in videos if path_key(f["library_root"]) == path_key(loc["root"]))
        print(f"- [{loc['library_name']}] {loc['root']} :: {count} videos")

    extension_counts = Counter(ntpath.splitext(f["path"])[1].casefold() for f in videos)
    print(f"\nFilesystem videos: {len(videos)}")
    print(f"Jellyfin expanded Episode paths in selected roots: {len(episode_paths)}")
    print("Video extensions:")
    for ext, count in sorted(extension_counts.items()):
        print(f"- {ext}: {count}")

    jellyfin_only, filesystem_only = diff_paths((f["path"] for f in videos), episode_paths)
    print(f"\nJELLYFIN_ONLY: {len(jellyfin_only)}")
    for path in jellyfin_only:
        print(f"  {path}")
    print(f"FILESYSTEM_ONLY: {len(filesystem_only)}")
    for path in filesystem_only:
        print(f"  {path}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Python inventory/mapping for Jellyfin full canonical view")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--run-log", default="jellyfin_tv_nfo_run_log.csv")
    parser.add_argument("--view-root", default=r"D:\Resource\BangumiLink\View")
    parser.add_argument("--expected-target-count", type=int, default=243)
    parser.add_argument("--exclude-root", action="append", default=[])
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    virtual_folders = jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    exclusions = list(DEFAULT_EXCLUDED_ROOTS) + list(args.exclude_root)
    locations = select_production_locations(virtual_folders, exclusions)
    if not locations:
        raise RuntimeError("no production tvshows locations remain after exclusions")
    files = enumerate_files(locations)
    episode_paths = get_expanded_episode_paths(args.server, args.api_key, locations)
    print_inventory_report(locations, files, episode_paths)

    targets = load_targets(args.run_log, args.expected_target_count)
    mappings = build_mapping(files, targets, args.view_root)
    role_counts = Counter(row["role"] for row in mappings)
    print("\nMapping roles:")
    for role, count in sorted(role_counts.items()):
        print(f"- {role}: {count}")
    print("\nNo files were written. --apply is intentionally not implemented in this milestone.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
