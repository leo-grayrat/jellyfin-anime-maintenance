#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ntpath
import sys
from collections import Counter
from typing import Sequence

import build_jellyfin_full_canonical_view as inv
import apply_jellyfin_full_canonical_view as core


DEFAULT_ROOT = r"D:\Resource\BangumiLink"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Preflight/apply isolated v3 canonical View without touching the validated v2 View"
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--run-log", default="jellyfin_tv_nfo_run_log.csv")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--expected-video-count", type=int, default=634)
    parser.add_argument("--expected-target-count", type=int, default=243)
    parser.add_argument("--exclude-root", action="append", default=[])
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def build_preflight(args: argparse.Namespace) -> dict:
    root = inv.normalize_windows_path(args.root)
    view_root = inv.normalize_windows_path(args.view_root)
    validated_v2 = ntpath.join(root, "View")
    if inv.path_key(view_root) == inv.path_key(validated_v2):
        raise ValueError("v3 refuses to use the validated v2 View root")
    if not inv.path_under_or_equal(view_root, root):
        raise ValueError(f"v3 View root must remain under {root}: {view_root}")

    temp_root = ntpath.join(root, "Temp")
    logs_root = ntpath.join(root, "Logs")
    full_manifest = ntpath.join(logs_root, "full-manifest-v3.csv")
    no_phase1_manifest = ntpath.join(logs_root, "__v3-no-phase1-manifest__.csv")

    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    exclusions = list(inv.DEFAULT_EXCLUDED_ROOTS) + [view_root] + list(args.exclude_root)
    locations = inv.select_production_locations(virtual_folders, exclusions)
    if not locations:
        raise RuntimeError("no D-drive production tvshows locations remain after exclusions")

    files = inv.enumerate_files(locations)
    videos = [row for row in files if inv.is_video(row["path"])]
    if len(videos) != args.expected_video_count:
        raise ValueError(
            f"expected {args.expected_video_count} D-drive View-scope videos, found {len(videos)}"
        )

    episode_paths = inv.get_expanded_episode_paths(args.server, args.api_key, locations)
    jellyfin_only, filesystem_only = inv.diff_paths((row["path"] for row in videos), episode_paths)
    if jellyfin_only or filesystem_only:
        raise ValueError(
            "filesystem/Jellyfin video sets differ: "
            f"JELLYFIN_ONLY={len(jellyfin_only)} FILESYSTEM_ONLY={len(filesystem_only)}"
        )

    targets = inv.load_targets(args.run_log, args.expected_target_count)
    core.validate_target_nfos(targets)
    mappings = inv.build_mapping(files, targets, view_root, layout_profile="v3")
    plan = core.enrich_plan(files, mappings)

    # v3 is a fresh parallel View. It deliberately does not inherit the Phase 1/v2 manifest.
    # Use a valid, intentionally absent path rather than an empty string because Windows
    # long-path normalization rejects empty paths before os.path.isfile() can return False.
    classified, previous_full = core.preflight_plan(
        plan,
        view_root,
        no_phase1_manifest,
        full_manifest,
        args.expected_target_count,
    )
    return {
        "root": root,
        "view_root": view_root,
        "temp_root": temp_root,
        "logs_root": logs_root,
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
    print("\n=== Python Full Canonical View v3 Preflight ===")
    print("Mode: READ ONLY")
    print(f"View root:          {result['view_root']}")
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

    print("\nRe-running v3 preflight immediately before Apply...")
    result = build_preflight(args)
    print_preflight(result)
    applied = core.apply_transaction(
        result["plan"],
        result["view_root"],
        result["temp_root"],
        result["logs_root"],
        result["full_manifest"],
    )
    print("\n=== Full View v3 Apply complete ===")
    print(f"Build id:     {applied['build_id']}")
    print(f"Created rows: {applied['created']}")
    print(f"Reused rows:  {applied['reused']}")
    print(f"Manifest:     {applied['manifest']}")
    print(f"Build log:    {applied['build_log']}")
    print("Validated v2 View and original media paths were not modified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
