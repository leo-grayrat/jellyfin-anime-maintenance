#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ntpath
import re
import sys
from collections import Counter, defaultdict
from typing import Sequence

import build_jellyfin_full_canonical_view as inv

DEFAULT_SERVER = "http://127.0.0.1:8096"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only audit for Jellyfin Series identity and metadata regression under View-v3."
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--output", default="", help="Optional CSV output path")
    parser.add_argument(
        "--previous",
        default="",
        help="Optional previous audit CSV. Used to detect whether the same path got a new Jellyfin item id or lost a provider id.",
    )
    return parser.parse_args(argv)


def path_key(path: str) -> str:
    return inv.path_key(path)


def _provider_id(item: dict, provider: str) -> str:
    ids = item.get("ProviderIds") or {}
    wanted = provider.casefold()
    for key, value in ids.items():
        if str(key).casefold() == wanted and str(value).strip():
            return str(value).strip()
    return ""


def _has_any_provider_id(item: dict) -> bool:
    return any(str(value).strip() for value in (item.get("ProviderIds") or {}).values())


def _has_primary_image(item: dict) -> bool:
    tags = item.get("ImageTags") or {}
    return any(str(key).casefold() == "primary" and str(value).strip() for key, value in tags.items())


def _has_overview(item: dict) -> bool:
    return bool(str(item.get("Overview") or "").strip())


def _normalize_name(value: str) -> str:
    value = str(value or "").strip().casefold()
    value = re.sub(r"\s+", " ", value)
    return value


def name_looks_path_derived(name: str, path: str, *, is_file: bool) -> bool:
    """Heuristic only: flag names that are effectively the local folder/file basename."""
    normalized_name = _normalize_name(name)
    if not normalized_name or not str(path or "").strip():
        return False

    component = ntpath.basename(str(path).rstrip("\\/"))
    if is_file:
        component = ntpath.splitext(component)[0]
    normalized_component = _normalize_name(component)
    if not normalized_component:
        return False

    if normalized_name == normalized_component:
        return True

    # Jellyfin/NFO may trim a leading release-group tag while leaving most of the filename behind.
    # Treat a long name occupying most of the local basename as path-derived too.
    if len(normalized_name) >= 12 and normalized_name in normalized_component:
        return len(normalized_name) / len(normalized_component) >= 0.45
    if len(normalized_component) >= 12 and normalized_component in normalized_name:
        return len(normalized_component) / len(normalized_name) >= 0.45
    return False


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


def load_previous_rows(path: str) -> dict[str, dict]:
    if not path:
        return {}
    rows: dict[str, dict] = {}
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            item_path = str(row.get("Path") or "").strip()
            if item_path:
                rows[path_key(item_path)] = row
    return rows


def _episode_stats(episode_items: Sequence[dict]) -> dict[str, dict]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for item in episode_items:
        grouped[str(item.get("SeriesId") or "")].append(item)

    stats: dict[str, dict] = {}
    for series_id, items in grouped.items():
        stats[series_id] = {
            "EpisodeCount": len(items),
            "EpisodeWithAnyProviderIdCount": sum(_has_any_provider_id(item) for item in items),
            "EpisodeWithTvdbIdCount": sum(bool(_provider_id(item, "Tvdb")) for item in items),
            "EpisodeWithOverviewCount": sum(_has_overview(item) for item in items),
            "EpisodeNameLooksLocalCount": sum(
                name_looks_path_derived(str(item.get("Name") or ""), str(item.get("Path") or ""), is_file=True)
                for item in items
            ),
        }
    return stats


def _regression_signals(
    *,
    item: dict,
    previous: dict | None,
    series_name_looks_local: bool,
    episode_stats: dict,
) -> str:
    signals: list[str] = []
    series_id = str(item.get("Id") or "")
    tvdb_id = _provider_id(item, "Tvdb")

    if previous:
        previous_id = str(previous.get("SeriesId") or "")
        previous_tvdb = str(previous.get("TvdbId") or "")
        if previous_id and previous_id != series_id:
            signals.append("ITEM_ID_CHANGED")
        if previous_tvdb and not tvdb_id:
            signals.append("TVDB_ID_LOST")

    if series_name_looks_local:
        signals.append("SERIES_NAME_LOOKS_LOCAL")
    if int(episode_stats.get("EpisodeNameLooksLocalCount") or 0) > 0:
        signals.append("EPISODE_NAMES_LOOK_LOCAL")

    return "|".join(signals)


def build_rows(
    series_items: Sequence[dict],
    episode_items: Sequence[dict],
    library_roots: Sequence[dict],
    view_root: str,
    *,
    previous_rows: dict[str, dict] | None = None,
) -> list[dict]:
    normalized_view = inv.normalize_windows_path(view_root)
    previous_rows = previous_rows or {}
    episode_stats_by_series = _episode_stats(episode_items)
    rows: list[dict] = []

    for item in series_items:
        path = str(item.get("Path") or "").strip()
        if not path or not inv.path_under_or_equal(path, normalized_view):
            continue
        library = choose_library(path, library_roots)
        if library is None:
            continue

        series_id = str(item.get("Id") or "")
        previous = previous_rows.get(path_key(path))
        previous_id = str((previous or {}).get("SeriesId") or "")
        previous_tvdb = str((previous or {}).get("TvdbId") or "")
        previous_name = str((previous or {}).get("SeriesName") or "")
        series_name_looks_local = name_looks_path_derived(
            str(item.get("Name") or ""), path, is_file=False
        )
        episode_stats = episode_stats_by_series.get(
            series_id,
            {
                "EpisodeCount": 0,
                "EpisodeWithAnyProviderIdCount": 0,
                "EpisodeWithTvdbIdCount": 0,
                "EpisodeWithOverviewCount": 0,
                "EpisodeNameLooksLocalCount": 0,
            },
        )

        row = {
            "LibraryName": library["library_name"],
            "SeriesName": str(item.get("Name") or ""),
            "SeriesId": series_id,
            "Path": inv.normalize_windows_path(path),
            "FolderName": ntpath.basename(path.rstrip("\\/")),
            "Year": item.get("ProductionYear") or "",
            "TvdbId": _provider_id(item, "Tvdb"),
            "TmdbId": _provider_id(item, "Tmdb"),
            "ImdbId": _provider_id(item, "Imdb"),
            "HasPrimaryImage": _has_primary_image(item),
            "HasSeriesOverview": _has_overview(item),
            "SeriesNameLooksLocal": series_name_looks_local,
            "DateLastRefreshed": str(item.get("DateLastRefreshed") or ""),
            "DateLastSaved": str(item.get("DateLastSaved") or ""),
            "PreviousSeriesId": previous_id,
            "ItemIdChanged": bool(previous_id and previous_id != series_id),
            "PreviousTvdbId": previous_tvdb,
            "PreviousSeriesName": previous_name,
            **episode_stats,
            "IdentityStatus": classify_series(item),
        }
        row["RegressionSignals"] = _regression_signals(
            item=item,
            previous=previous,
            series_name_looks_local=series_name_looks_local,
            episode_stats=episode_stats,
        )
        rows.append(row)

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
                "Fields": "Path,ProviderIds,ProductionYear,Overview,DateLastRefreshed,DateLastSaved",
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
        "FolderName",
        "Year",
        "TvdbId",
        "TmdbId",
        "ImdbId",
        "HasPrimaryImage",
        "HasSeriesOverview",
        "SeriesNameLooksLocal",
        "DateLastRefreshed",
        "DateLastSaved",
        "PreviousSeriesId",
        "ItemIdChanged",
        "PreviousTvdbId",
        "PreviousSeriesName",
        "EpisodeCount",
        "EpisodeWithAnyProviderIdCount",
        "EpisodeWithTvdbIdCount",
        "EpisodeWithOverviewCount",
        "EpisodeNameLooksLocalCount",
        "IdentityStatus",
        "RegressionSignals",
    ]
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(rows: Sequence[dict], view_root: str, has_previous: bool) -> None:
    identity_counts = Counter(row["IdentityStatus"] for row in rows)
    signal_counts = Counter(
        signal
        for row in rows
        for signal in str(row["RegressionSignals"] or "").split("|")
        if signal
    )
    review = [
        row
        for row in rows
        if row["IdentityStatus"] != "OK" or row["RegressionSignals"]
    ]

    print("\n=== Jellyfin Series Metadata Audit ===")
    print("Mode: READ ONLY")
    print(f"View root: {inv.normalize_windows_path(view_root)}")
    print(f"Series:    {len(rows)}")
    print(f"Identity OK: {identity_counts.get('OK', 0)}")
    print(f"Need review: {len(review)}")
    print(f"Series name looks local: {signal_counts.get('SERIES_NAME_LOOKS_LOCAL', 0)}")
    print(f"Episode names look local: {signal_counts.get('EPISODE_NAMES_LOOK_LOCAL', 0)}")
    if has_previous:
        print(f"Item id changed: {signal_counts.get('ITEM_ID_CHANGED', 0)}")
        print(f"TVDB id lost vs previous audit: {signal_counts.get('TVDB_ID_LOST', 0)}")

    if review:
        print("\n--- Need Review ---")
        for row in review:
            ids = f"TVDB={row['TvdbId'] or '-'} TMDB={row['TmdbId'] or '-'} IMDb={row['ImdbId'] or '-'}"
            print(
                f"[{row['IdentityStatus']}] [{row['LibraryName']}] {row['SeriesName']}\n"
                f"  signals={row['RegressionSignals'] or '-'}; {ids}; "
                f"episodes={row['EpisodeCount']}; episode-overview={row['EpisodeWithOverviewCount']}; "
                f"episode-local-name={row['EpisodeNameLooksLocalCount']}\n"
                f"  id={row['SeriesId']} previous-id={row['PreviousSeriesId'] or '-'}\n"
                f"  refreshed={row['DateLastRefreshed'] or '-'} saved={row['DateLastSaved'] or '-'}\n"
                f"  {row['Path']}"
            )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    virtual_folders = inv.jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    roots = build_library_roots(virtual_folders, args.view_root)
    if not roots:
        raise RuntimeError(f"no Jellyfin tvshows locations found under {inv.normalize_windows_path(args.view_root)}")

    previous_rows = load_previous_rows(args.previous)
    series_items = get_paged_items(args.server, args.api_key, "Series")
    episode_items = get_paged_items(args.server, args.api_key, "Episode")
    rows = build_rows(
        series_items,
        episode_items,
        roots,
        args.view_root,
        previous_rows=previous_rows,
    )
    print_summary(rows, args.view_root, bool(args.previous))

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
