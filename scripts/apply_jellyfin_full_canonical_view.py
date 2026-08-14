#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import filecmp
import ntpath
import os
import shutil
import stat
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime
from typing import Iterable, Sequence

import build_jellyfin_full_canonical_view as inv

SUBTITLE_EXTENSIONS = {".ass", ".ssa", ".srt", ".vtt", ".sub", ".idx"}
MANIFEST_FIELDS = [
    "SourcePath",
    "CanonicalPath",
    "LibraryName",
    "Role",
    "Operation",
    "SourceLength",
    "ExpectedKey",
    "BuildId",
    "Status",
]


def operation_for_path(path: str) -> str:
    if inv.is_video(path):
        return "HARDLINK"
    if ntpath.splitext(path)[1].casefold() in SUBTITLE_EXTENSIONS:
        return "HARDLINK"
    return "COPY"


def native_path(path: str) -> str:
    if os.name != "nt":
        return path
    return inv._to_extended_windows_path(path)


def file_exists(path: str) -> bool:
    return os.path.isfile(native_path(path))


def file_size(path: str) -> int:
    return os.path.getsize(native_path(path))


def ensure_parent(path: str) -> list[str]:
    parent = os.path.dirname(native_path(path))
    if not parent:
        return []
    missing: list[str] = []
    cursor = parent
    while cursor and not os.path.exists(cursor):
        missing.append(cursor)
        next_cursor = os.path.dirname(cursor)
        if next_cursor == cursor:
            break
        cursor = next_cursor
    os.makedirs(parent, exist_ok=True)
    return list(reversed(missing))


def read_csv_if_present(path: str) -> list[dict]:
    actual = native_path(path)
    if not os.path.isfile(actual):
        return []
    with open(actual, "r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: str, rows: Iterable[dict], fieldnames: Sequence[str]) -> None:
    actual = native_path(path)
    parent = os.path.dirname(actual)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(actual, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def validate_target_nfos(targets: Sequence[dict]) -> None:
    for target in targets:
        nfo_path = ntpath.splitext(target["video_path"])[0] + ".nfo"
        actual = native_path(nfo_path)
        if not os.path.isfile(actual):
            raise ValueError(f"correction target NFO is missing: {nfo_path}")
        try:
            root = ET.parse(actual).getroot()
        except ET.ParseError as exc:
            raise ValueError(f"correction target NFO is invalid XML: {nfo_path}: {exc}") from exc
        season_text = root.findtext(".//season")
        episode_text = root.findtext(".//episode")
        if season_text is None or episode_text is None:
            raise ValueError(f"correction target NFO is missing season/episode: {nfo_path}")
        if int(season_text.strip()) != int(target["season"]) or int(episode_text.strip()) != int(target["episode"]):
            raise ValueError(f"correction target NFO identity mismatch: {nfo_path}")


def enrich_plan(files: Sequence[dict], mappings: Sequence[dict]) -> list[dict]:
    source_files = {inv.path_key(row["path"]): row for row in files}
    result: list[dict] = []
    for mapping in mappings:
        source = source_files.get(inv.path_key(mapping["source_path"]))
        if source is None:
            raise ValueError(f"mapping source missing from inventory: {mapping['source_path']}")
        operation = operation_for_path(mapping["source_path"])
        if operation == "HARDLINK":
            source_drive = ntpath.splitdrive(inv.normalize_windows_path(mapping["source_path"]))[0].casefold()
            target_drive = ntpath.splitdrive(inv.normalize_windows_path(mapping["canonical_path"]))[0].casefold()
            if source_drive != target_drive:
                raise ValueError(f"hardlink crosses volumes: {mapping['source_path']} -> {mapping['canonical_path']}")
        result.append(
            {
                **mapping,
                "operation": operation,
                "source_size": int(source["size"]),
                "state": "UNCLASSIFIED",
                "reason": "",
            }
        )
    return result


def manifest_row_from_plan(row: dict, build_id: str, status: str) -> dict:
    return {
        "SourcePath": row["source_path"],
        "CanonicalPath": row["canonical_path"],
        "LibraryName": row["library_name"],
        "Role": row["role"],
        "Operation": row["operation"],
        "SourceLength": str(row["source_size"]),
        "ExpectedKey": row.get("expected_key", ""),
        "BuildId": build_id,
        "Status": status,
    }


def manifest_index(rows: Sequence[dict]) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for row in rows:
        canonical = (row.get("CanonicalPath") or "").strip()
        if not canonical:
            raise ValueError("manifest row is missing CanonicalPath")
        key = inv.path_key(canonical)
        if key in result:
            raise ValueError(f"duplicate canonical path in manifest: {canonical}")
        result[key] = row
    return result


def merge_manifest_rows(existing: Sequence[dict], newer: Sequence[dict]) -> list[dict]:
    result = manifest_index(existing)
    for row in newer:
        key = inv.path_key(row["CanonicalPath"])
        previous = result.get(key)
        if previous is not None and inv.path_key(previous["SourcePath"]) != inv.path_key(row["SourcePath"]):
            raise ValueError(f"canonical path changed source ownership: {row['CanonicalPath']}")
        result[key] = row
    return sorted(result.values(), key=lambda row: inv.path_key(row["CanonicalPath"]))


def phase1_seed_rows(phase1_manifest_path: str, plan: Sequence[dict], expected_targets: int) -> list[dict]:
    old_rows = read_csv_if_present(phase1_manifest_path)
    if not old_rows:
        return []
    if len(old_rows) != expected_targets:
        raise ValueError(f"Phase 1 manifest has {len(old_rows)} rows, expected {expected_targets}")

    by_source = {inv.path_key(row["source_path"]): row for row in plan}
    seeds: list[dict] = []
    for old in old_rows:
        pairs = [
            (old.get("OriginalVideo", ""), old.get("CanonicalVideo", ""), "CORRECTION_VIDEO"),
            (old.get("OriginalNfo", ""), old.get("CanonicalNfo", ""), "CORRECTION_SIDECAR"),
        ]
        for source, canonical, role in pairs:
            if not source or not canonical:
                raise ValueError("Phase 1 manifest row is missing source/canonical path")
            current = by_source.get(inv.path_key(source))
            if current is None:
                raise ValueError(f"Phase 1 source is absent from current plan: {source}")
            if current["role"] != role:
                raise ValueError(f"Phase 1 role differs from current plan: {source}")
            if inv.path_key(current["canonical_path"]) != inv.path_key(canonical):
                raise ValueError(f"Phase 1 canonical path differs from current plan: {canonical}")
            seeds.append(manifest_row_from_plan(current, f"phase1-{old.get('BuildId', '')}", "PHASE1"))
    return seeds


def classify_existing(row: dict, owners: dict[str, dict]) -> tuple[str, str]:
    target = row["canonical_path"]
    if not file_exists(target):
        return "MISSING", "target does not exist"
    owner = owners.get(inv.path_key(target))
    if owner is None:
        return "CONFLICT", "target exists but is unmanaged"
    if inv.path_key(owner["SourcePath"]) != inv.path_key(row["source_path"]):
        return "CONFLICT", "manifest source does not match current source"
    if file_size(target) != int(row["source_size"]):
        return "CONFLICT", "target size differs from source"
    if row["operation"] == "HARDLINK":
        try:
            if not os.path.samefile(native_path(row["source_path"]), native_path(target)):
                return "CONFLICT", "managed HARDLINK is not the same file as source"
        except OSError as exc:
            return "CONFLICT", f"cannot verify hardlink identity: {exc}"
    elif row["operation"] == "COPY":
        try:
            if not filecmp.cmp(native_path(row["source_path"]), native_path(target), shallow=False):
                return "CONFLICT", "managed COPY content differs from source"
        except OSError as exc:
            return "CONFLICT", f"cannot compare managed copy: {exc}"
    return "REUSABLE", "managed same source"


def enumerate_tree_files(root: str) -> list[str]:
    if not os.path.isdir(native_path(root)):
        return []
    result: list[str] = []
    stack = [native_path(root)]
    while stack:
        directory = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                if entry.is_symlink():
                    continue
                entry_stat = entry.stat(follow_symlinks=False)
                if os.name == "nt":
                    attributes = getattr(entry_stat, "st_file_attributes", 0)
                    if attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
                        continue
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
                elif entry.is_file(follow_symlinks=False):
                    path = entry.path
                    if os.name == "nt" and path.startswith("\\\\?\\UNC\\"):
                        path = r"\\" + path[8:]
                    elif os.name == "nt" and path.startswith("\\\\?\\"):
                        path = path[4:]
                    result.append(path)
    return result


def preflight_plan(
    plan: Sequence[dict],
    view_root: str,
    phase1_manifest_path: str,
    full_manifest_path: str,
    expected_targets: int,
) -> tuple[list[dict], list[dict]]:
    phase1 = phase1_seed_rows(phase1_manifest_path, plan, expected_targets)
    full = read_csv_if_present(full_manifest_path)
    effective = merge_manifest_rows(phase1, full)
    owners = manifest_index(effective)
    plan_by_canonical = {inv.path_key(row["canonical_path"]): row for row in plan}

    for row in full:
        if inv.path_key(row["CanonicalPath"]) not in plan_by_canonical:
            raise ValueError(f"full manifest contains stale canonical path: {row['CanonicalPath']}")

    for path in enumerate_tree_files(view_root):
        key = inv.path_key(path)
        if key not in owners:
            raise ValueError(f"View contains unmanaged file: {path}")
        if key not in plan_by_canonical:
            raise ValueError(f"View contains stale managed file: {path}")

    classified: list[dict] = []
    conflicts: list[str] = []
    for source_row in plan:
        row = dict(source_row)
        state, reason = classify_existing(row, owners)
        row["state"] = state
        row["reason"] = reason
        classified.append(row)
        if state == "CONFLICT":
            conflicts.append(f"{row['canonical_path']} :: {reason}")
    if conflicts:
        raise ValueError(f"preflight found {len(conflicts)} conflict(s): {' | '.join(conflicts[:10])}")
    return classified, full


def verify_created(row: dict) -> None:
    target = row["canonical_path"]
    if not file_exists(target):
        raise RuntimeError(f"destination is missing after create: {target}")
    if file_size(target) != int(row["source_size"]):
        raise RuntimeError(f"destination size differs after create: {target}")
    if row["operation"] == "HARDLINK" and not os.path.samefile(native_path(row["source_path"]), native_path(target)):
        raise RuntimeError(f"hardlink destination is not same file as source: {target}")
    if row["operation"] == "COPY" and not filecmp.cmp(native_path(row["source_path"]), native_path(target), shallow=False):
        raise RuntimeError(f"copy destination differs from source: {target}")


def apply_transaction(
    plan: Sequence[dict],
    view_root: str,
    temp_root: str,
    logs_root: str,
    full_manifest_path: str,
) -> dict:
    build_id = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    join = ntpath.join if os.name == "nt" else os.path.join
    build_temp = join(temp_root, f"full-build-{build_id}")
    build_log_path = join(logs_root, f"full-build-{build_id}.csv")
    manifest_temp = join(build_temp, "full-manifest-v2.csv")
    plan_path = join(build_temp, "plan.csv")

    os.makedirs(native_path(build_temp), exist_ok=False)
    os.makedirs(native_path(logs_root), exist_ok=True)
    write_csv(
        plan_path,
        plan,
        ["source_path", "canonical_path", "library_name", "role", "operation", "source_size", "expected_key", "state", "reason"],
    )

    created_files: list[str] = []
    created_dirs: list[str] = []
    build_rows: list[dict] = []
    manifest_committed = False
    try:
        for index, row in enumerate(plan, 1):
            status = "REUSED"
            if row["state"] == "MISSING":
                for directory in ensure_parent(row["canonical_path"]):
                    if directory not in created_dirs:
                        created_dirs.append(directory)
                if row["operation"] == "HARDLINK":
                    os.link(native_path(row["source_path"]), native_path(row["canonical_path"]))
                elif row["operation"] == "COPY":
                    shutil.copy2(native_path(row["source_path"]), native_path(row["canonical_path"]))
                else:
                    raise RuntimeError(f"unsupported operation: {row['operation']}")
                created_files.append(row["canonical_path"])
                verify_created(row)
                status = "CREATED"
            elif row["state"] != "REUSABLE":
                raise RuntimeError(f"Apply received non-ready row: {row['canonical_path']} state={row['state']}")

            build_rows.append(manifest_row_from_plan(row, build_id, status))
            if index % 100 == 0 or index == len(plan):
                print(f"Ready: {index} / {len(plan)}")

        write_csv(build_log_path, build_rows, MANIFEST_FIELDS)
        write_csv(manifest_temp, build_rows, MANIFEST_FIELDS)
        os.replace(native_path(manifest_temp), native_path(full_manifest_path))
        manifest_committed = True
        return {
            "build_id": build_id,
            "created": sum(1 for row in build_rows if row["Status"] == "CREATED"),
            "reused": sum(1 for row in build_rows if row["Status"] == "REUSED"),
            "manifest": full_manifest_path,
            "build_log": build_log_path,
        }
    except Exception:
        if not manifest_committed:
            print("Rollback: removing only files created by this build under View...", file=sys.stderr)
            for path in reversed(created_files):
                if os.name == "nt" and not inv.path_under_or_equal(path, view_root):
                    continue
                try:
                    os.remove(native_path(path))
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
            for directory in reversed(created_dirs):
                try:
                    os.rmdir(directory)
                except OSError:
                    pass
        raise


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Preflight/apply Python full canonical View")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--run-log", default="jellyfin_tv_nfo_run_log.csv")
    parser.add_argument("--root", default=r"D:\Resource\BangumiLink")
    parser.add_argument("--expected-video-count", type=int, default=634)
    parser.add_argument("--expected-target-count", type=int, default=243)
    parser.add_argument("--exclude-root", action="append", default=[])
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def build_preflight(args: argparse.Namespace) -> dict:
    root = inv.normalize_windows_path(args.root)
    view_root = ntpath.join(root, "View")
    temp_root = ntpath.join(root, "Temp")
    logs_root = ntpath.join(root, "Logs")
    phase1_manifest = ntpath.join(logs_root, "manifest.csv")
    full_manifest = ntpath.join(logs_root, "full-manifest-v2.csv")

    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    locations = inv.select_production_locations(
        virtual_folders,
        list(inv.DEFAULT_EXCLUDED_ROOTS) + list(args.exclude_root),
    )
    if not locations:
        raise RuntimeError("no production tvshows locations remain after exclusions")
    files = inv.enumerate_files(locations)
    videos = [row for row in files if inv.is_video(row["path"])]
    if len(videos) != args.expected_video_count:
        raise ValueError(f"expected {args.expected_video_count} production videos, found {len(videos)}")

    episode_paths = inv.get_expanded_episode_paths(args.server, args.api_key, locations)
    jellyfin_only, filesystem_only = inv.diff_paths((row["path"] for row in videos), episode_paths)
    if jellyfin_only or filesystem_only:
        raise ValueError(
            f"filesystem/Jellyfin video sets differ: JELLYFIN_ONLY={len(jellyfin_only)} FILESYSTEM_ONLY={len(filesystem_only)}"
        )

    targets = inv.load_targets(args.run_log, args.expected_target_count)
    validate_target_nfos(targets)
    mappings = inv.build_mapping(files, targets, view_root)
    plan = enrich_plan(files, mappings)
    classified, previous_full = preflight_plan(
        plan,
        view_root,
        phase1_manifest,
        full_manifest,
        args.expected_target_count,
    )
    return {
        "root": root,
        "view_root": view_root,
        "temp_root": temp_root,
        "logs_root": logs_root,
        "phase1_manifest": phase1_manifest,
        "full_manifest": full_manifest,
        "locations": locations,
        "files": files,
        "videos": videos,
        "targets": targets,
        "plan": classified,
        "previous_full": previous_full,
    }


def print_preflight(result: dict) -> None:
    plan = result["plan"]
    roles = Counter(row["role"] for row in plan)
    operations = Counter(row["operation"] for row in plan)
    states = Counter(row["state"] for row in plan)
    print("\n=== Python Full Canonical View Preflight ===")
    print("Mode: READ ONLY")
    print(f"Production roots:   {len(result['locations'])}")
    print(f"Source files:       {len(result['files'])}")
    print(f"Source videos:      {len(result['videos'])}")
    print(f"Correction targets: {len(result['targets'])}")
    for role, count in sorted(roles.items()):
        print(f"{role}: {count}")
    print(f"HARDLINK rows:      {operations.get('HARDLINK', 0)}")
    print(f"COPY rows:          {operations.get('COPY', 0)}")
    print(f"Reusable rows:      {states.get('REUSABLE', 0)}")
    print(f"Rows to create:     {states.get('MISSING', 0)}")
    print("Conflicts:          0")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    result = build_preflight(args)
    print_preflight(result)
    if not args.apply:
        print("\nDRY RUN finished. No files were written.")
        return 0

    print("\nRe-running preflight immediately before Apply...")
    result = build_preflight(args)
    print_preflight(result)
    applied = apply_transaction(
        result["plan"],
        result["view_root"],
        result["temp_root"],
        result["logs_root"],
        result["full_manifest"],
    )
    print("\n=== Full View Apply complete ===")
    print(f"Build id:     {applied['build_id']}")
    print(f"Created rows: {applied['created']}")
    print(f"Reused rows:  {applied['reused']}")
    print(f"Manifest:     {applied['manifest']}")
    print(f"Build log:    {applied['build_log']}")
    print("Original media paths were not renamed, moved, overwritten, or deleted.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
