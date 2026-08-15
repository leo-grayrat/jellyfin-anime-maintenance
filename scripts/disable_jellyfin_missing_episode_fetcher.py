#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import ntpath
import sys
from typing import Callable, Sequence

import build_jellyfin_full_canonical_view as inv
import create_jellyfin_grouped_libraries as grouped

DEFAULT_SERVER = "http://127.0.0.1:8096"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"
FETCHER_NAME = "Missing Episode Fetcher"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Disable Jellyfin TheTVDB's missing-episode fetcher only for grouped TV libraries "
            "directly under View-v3. TheTVDB metadata/image fetchers are preserved."
        )
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--apply", action="store_true", help="Actually update library options; default is dry-run")
    return parser.parse_args(argv)


def _remove_fetcher(values) -> tuple[list, int]:
    if not isinstance(values, list):
        return values, 0
    kept = []
    removed = 0
    for value in values:
        if str(value).strip().casefold() == FETCHER_NAME.casefold():
            removed += 1
        else:
            kept.append(value)
    return kept, removed


def remove_missing_episode_fetcher(options: dict) -> tuple[dict, int]:
    updated = copy.deepcopy(options or {})
    removed = 0

    if "MetadataFetchers" in updated:
        updated["MetadataFetchers"], count = _remove_fetcher(updated.get("MetadataFetchers"))
        removed += count

    type_options = updated.get("TypeOptions")
    if isinstance(type_options, list):
        for row in type_options:
            if not isinstance(row, dict) or "MetadataFetchers" not in row:
                continue
            row["MetadataFetchers"], count = _remove_fetcher(row.get("MetadataFetchers"))
            removed += count

    return updated, removed


def _is_direct_child_location(location: str, view_root: str) -> bool:
    path = inv.normalize_windows_path(location)
    root = inv.normalize_windows_path(view_root)
    if not inv.path_under_or_equal(path, root) or inv.path_key(path) == inv.path_key(root):
        return False
    parent = inv.normalize_windows_path(ntpath.dirname(path))
    return inv.path_key(parent) == inv.path_key(root)


def _is_target_library(folder: dict, view_root: str) -> bool:
    if str(folder.get("CollectionType") or "") != "tvshows":
        return False
    locations = [str(value).strip() for value in (folder.get("Locations") or []) if str(value).strip()]
    if len(locations) != 1:
        return False
    return _is_direct_child_location(locations[0], view_root)


def build_plan(virtual_folders, view_root: str) -> list[dict]:
    plan: list[dict] = []
    for folder in grouped.flatten_virtual_folders(virtual_folders):
        if not _is_target_library(folder, view_root):
            continue
        options = folder.get("LibraryOptions")
        if not isinstance(options, dict):
            raise ValueError(f"library has no LibraryOptions: {folder.get('Name')}")
        item_id = str(folder.get("ItemId") or "").strip()
        if not item_id:
            raise ValueError(f"library has no ItemId: {folder.get('Name')}")

        updated_options, removed = remove_missing_episode_fetcher(options)
        plan.append(
            {
                "name": str(folder.get("Name") or ""),
                "item_id": item_id,
                "location": inv.normalize_windows_path((folder.get("Locations") or [""])[0]),
                "state": "UPDATE" if removed else "SKIP",
                "removed": removed,
                "updated_options": updated_options,
            }
        )

    plan.sort(key=lambda row: row["name"].casefold())
    if not plan:
        raise RuntimeError(
            f"no single-path tvshows libraries found directly under {inv.normalize_windows_path(view_root)}"
        )
    return plan


def apply_plan(
    server: str,
    api_key: str,
    plan: Sequence[dict],
    request_fn: Callable = grouped.jellyfin_request,
) -> int:
    changed = 0
    for row in plan:
        if row["state"] != "UPDATE":
            continue
        request_fn(
            server,
            api_key,
            "POST",
            "/Library/VirtualFolders/LibraryOptions",
            body={
                "Id": row["item_id"],
                "LibraryOptions": row["updated_options"],
            },
        )
        changed += 1
    return changed


def print_plan(plan: Sequence[dict], view_root: str) -> None:
    updates = sum(row["state"] == "UPDATE" for row in plan)
    skips = sum(row["state"] == "SKIP" for row in plan)
    print("\n=== Disable TVDB Missing Episode Fetcher ===")
    print(f"View root: {inv.normalize_windows_path(view_root)}")
    print(f"Libraries: {len(plan)}")
    print(f"To update: {updates}")
    print(f"Already disabled: {skips}")
    print("")
    for row in plan:
        print(
            f"[{row['state']:<6}] {row['name']} :: removed={row['removed']} :: {row['location']}"
        )
    print("\nTheTVDB metadata/image fetchers are not removed by this script.")
    print("No library scan is triggered automatically.")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    virtual_folders = grouped.jellyfin_request(
        args.server,
        args.api_key,
        "GET",
        "/Library/VirtualFolders",
    )
    plan = build_plan(virtual_folders, args.view_root)
    print_plan(plan, args.view_root)

    if not args.apply:
        print("\nDRY RUN finished. Jellyfin was not changed.")
        return 0

    # Re-read immediately before mutation so we never apply an old options snapshot.
    virtual_folders = grouped.jellyfin_request(
        args.server,
        args.api_key,
        "GET",
        "/Library/VirtualFolders",
    )
    plan = build_plan(virtual_folders, args.view_root)
    changed = apply_plan(args.server, args.api_key, plan)
    print(f"\nUpdated {changed} libraries.")
    print("No scan was triggered. Existing virtual missing episodes were not deleted by this script.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
