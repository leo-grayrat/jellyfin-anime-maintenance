#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from typing import Sequence

import build_jellyfin_full_canonical_view as inv

DEFAULT_ROOT = r"D:\Resource\BangumiLink\MetadataPilot-v3\2026年1月新番"
TARGETS = {
    "209867": {(2, 2), (2, 6)},
    "203737": {(3, 2), (3, 7)},
}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Jellyfin Episode lookup-input diagnostic")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    return parser.parse_args(argv)


def get_items(server: str, api_key: str, item_type: str) -> list[dict]:
    response = inv.jellyfin_get(
        server,
        api_key,
        "/Items",
        {
            "Recursive": "true",
            "IncludeItemTypes": item_type,
            "Fields": "Path,ProviderIds,ParentId,SeriesId,SeasonId",
            "EnableImages": "false",
            "EnableUserData": "false",
        },
    )
    return list(response.get("Items") or [])


def get_full_item(server: str, api_key: str, item_id: str) -> dict:
    return inv.jellyfin_get(server, api_key, f"/Items/{item_id}")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = inv.normalize_windows_path(args.root)

    series_rows = []
    for item in get_items(args.server, args.api_key, "Series"):
        path = str(item.get("Path") or "").strip()
        if not path or not inv.path_under_or_equal(path, root):
            continue
        full = get_full_item(args.server, args.api_key, str(item.get("Id") or ""))
        tmdb = str((full.get("ProviderIds") or {}).get("Tmdb") or "")
        if tmdb in TARGETS:
            series_rows.append(full)

    if len(series_rows) != len(TARGETS):
        found = [str((row.get("ProviderIds") or {}).get("Tmdb") or "") for row in series_rows]
        raise RuntimeError(f"expected {len(TARGETS)} target Series under pilot root, found {len(series_rows)}: {found}")

    episodes = []
    for item in get_items(args.server, args.api_key, "Episode"):
        path = str(item.get("Path") or "").strip()
        if path and inv.path_under_or_equal(path, root):
            episodes.append(get_full_item(args.server, args.api_key, str(item.get("Id") or "")))

    print("=== Jellyfin Episode Lookup Input Diagnostic ===")
    print("Mode: READ ONLY")
    print(f"Root: {root}")

    for series in sorted(series_rows, key=lambda row: str(row.get("Name") or "")):
        tmdb = str((series.get("ProviderIds") or {}).get("Tmdb") or "")
        series_id = str(series.get("Id") or "")
        print("\nSeries:")
        print(f"  Name:                      {series.get('Name') or ''}")
        print(f"  Id:                        {series_id}")
        print(f"  Path:                      {series.get('Path') or ''}")
        print(f"  Tmdb:                      {tmdb}")
        print(f"  DisplayOrder:              {series.get('DisplayOrder')!r}")
        print(f"  PreferredMetadataLanguage:{series.get('PreferredMetadataLanguage')!r}")
        print(f"  PreferredMetadataCountry: {series.get('PreferredMetadataCountryCode')!r}")
        print(f"  ProviderIds:               {series.get('ProviderIds') or {}}")

        wanted = TARGETS[tmdb]
        matches = []
        for episode in episodes:
            if str(episode.get("SeriesId") or "") != series_id:
                continue
            key = (episode.get("ParentIndexNumber"), episode.get("IndexNumber"))
            if key in wanted:
                matches.append(episode)

        print("  Target Episodes:")
        for episode in sorted(matches, key=lambda row: (row.get("ParentIndexNumber") or -1, row.get("IndexNumber") or -1)):
            print(
                "    "
                f"S{int(episode.get('ParentIndexNumber')):02d}E{int(episode.get('IndexNumber')):02d} "
                f"Name={episode.get('Name')!r} "
                f"ProviderIds={episode.get('ProviderIds') or {}}"
            )
        if len(matches) != len(wanted):
            print(f"    WARNING: expected {len(wanted)} target episodes, found {len(matches)}")

    print("\nNo Jellyfin metadata or files were changed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
