#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from typing import Sequence

import build_jellyfin_full_canonical_view as inv

DEFAULT_SERVER = "http://127.0.0.1:8096"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only Series identity audit for Jellyfin TV content under View-v3."
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--output", default="", help="Optional CSV output path")
    return parser.parse_args(argv)


def _provider_id(item: dict, provider: str) -> str:
    ids = item.get("ProviderIds") or {}
    wanted = provider.casefold()
    for key, value in ids.items():
        if str(key).casefold() == wanted and str(value).strip():
            return str(value).strip()
    return ""


def _has_primary_image(item: dict) -> bool:
    tags = item.get("ImageTags") or {}
    return any(str(key).casefold() == "primary" and str(value).strip() for key, value in tags.items())


def classify_series(item: dict) -> str:
    has_tvdb = bool(_provider_id(item, "Tvdb"))
    has_image = _has_primary_image(item)
    if has_tvdb and has_image:
        return "OK"
    if not has_tvdb and not has_image:
        return "NO_TVDB_AND_IMAGE"
    if not has_tvdb:
        return "NO_TVDB_ID"
    return "NO_PRIMARY_IMAGE"


def choose_library(series_path: str, library_roots: Sequence[dict]) -> dict | None:
    if not str(series_path).strip():
        return None
    matches = [
        root
        for root in library_roots
        if inv.path_under_or_equal(series_path, root["root"])
    ]
    if not matches:
        return None
    return sorted(
        matches,
        key=lambda row: (-len(inv.normalize_windows_path(row["root"])), row["library_name"].casefold()),
    )[0]


def build_library_roots(virtual_folders, view_root: str) -> list[dict]:
    normalized_view = inv.normalize_windows_path(view_root)
    roots: list[dict] = []
    for folder in inv.flatten_virtual_folders(virtual_folders):
        for location in folder.get("Locations") or []:
            if not str(location).strip():
                continue
            normalized = inv.normalize_windows_path(str(location))
            if not inv.path_under_or_equal(normalized, normalized_view):
                continue
            roots.append(
                {
                    "library_name": str(folder.get("Name") or ""),
                    "library_item_id": str(folder.get("ItemId") or ""),
                    "root": normalized,
                }
            )
    roots.sort(key=lambda row: (row["library_name"].casefold(), inv.path_key(row["root"])))
    return roots


def build_rows(
    series_items: Sequence[dict],
    episode_items: Sequence[dict],
    library_roots: Sequence[dict],
    view_root: str,
) -> list[dict]:
    normalized_view = inv.normalize_windows_path(view_root)
    episode_counts = Counter(str(item.get("SeriesId") or "") for item in episode_items)
    rows: list[dict] = []

    for item in series_items:
        path = str(item.get("Path") or "").strip()
        if not path or not inv.path_under_or_equal(path, normalized_view):
            continue
        library = choose_library(path, library_roots)
        if library is None:
            continue

        series_id = str(item.get("Id") or "")
        rows.append(
            {
                "LibraryName": library["library_name"],
                "SeriesName": str(item.get("Name") or ""),
                "SeriesId": series_id,
                "Path": inv.normalize_windows_path(path),
                "Year": item.get("ProductionYear") or "",
                "TvdbId": _provider_id(item, "Tvdb"),
                "TmdbId": _provider_id(item, "Tmdb"),
                "ImdbId": _provider_id(item, "Imdb"),
                "HasPrimaryImage": _has_primary_image(item),
                "EpisodeCount": int(episode_counts.get(series_id, 0)),
                "Status": classify_series(item),
            }
        )

    rows.sort(key=lambda row: (row["LibraryName"].casefold(), row["SeriesName"].casefold(), row["Path"].casefold()))
    return rows


def get_paged_items(server: str, api_key: str, item_type: str) -> list[dict]:
    start = 0
    limit = 500
    result: list[dict] = []
    while True:
        response = inv.jellyfin_get(
            server,
            api_key,
            "/Items",
            {
                "Recursive": "true",
                "StartIndex": start,
                "Limit": limit,
                "IncludeItemTypes": item_type,
                "Fields": "Path,ProviderIds,ProductionYear",
                "EnableImages": "true",
                "ImageTypeLimit": 1,
                "EnableUserData": "false",
            },
        )
        items = response.get("Items") or []
        result.extend(items)
        start += len(items)
        total = int(response.get("TotalRecordCount") or 0)
        if not items or start >= total:
            break
    return result


def write_csv(path: str, rows: Sequence[dict]) -> None:
    fieldnames = [
        "LibraryName",
        "SeriesName",
        "SeriesId",
        "Path",
        "Year",
        "TvdbId",
        "TmdbId",
        "ImdbId",
        "HasPrimaryImage",
        "EpisodeCount",
        "Status",
    ]
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(rows: Sequence[dict], view_root: str) -> None:
    counts = Counter(row["Status"] for row in rows)
    abnormal = [row for row in rows if row["Status"] != "OK"]
    print("\n=== Jellyfin Series Identity Audit ===")
    print("Mode: READ ONLY")
    print(f"View root: {inv.normalize_windows_path(view_root)}")
    print(f"Series:    {len(rows)}")
    print(f"OK:        {counts.get('OK', 0)}")
    print(f"Abnormal:  {len(abnormal)}")
    for status in ("NO_TVDB_ID", "NO_PRIMARY_IMAGE", "NO_TVDB_AND_IMAGE"):
        print(f"{status}: {counts.get(status, 0)}")

    if abnormal:
        print("\n--- Abnormal Series ---")
        for row in abnormal:
            ids = f"TVDB={row['TvdbId'] or '-'} TMDB={row['TmdbId'] or '-'} IMDb={row['ImdbId'] or '-'}"
            print(
                f"[{row['Status']}] [{row['LibraryName']}] {row['SeriesName']} "
                f"({ids}; episodes={row['EpisodeCount']})\n  {row['Path']}"
            )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    roots = build_library_roots(virtual_folders, args.view_root)
    if not roots:
        raise RuntimeError(f"no Jellyfin tvshows locations found under {inv.normalize_windows_path(args.view_root)}")

    series_items = get_paged_items(args.server, args.api_key, "Series")
    episode_items = get_paged_items(args.server, args.api_key, "Episode")
    rows = build_rows(series_items, episode_items, roots, args.view_root)
    print_summary(rows, args.view_root)

    if args.output:
        write_csv(args.output, rows)
        print(f"\nCSV: {args.output}")
    print("\nREAD ONLY: no Jellyfin metadata, library setting, NFO, media file, or database was changed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
