#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ntpath
import sys
from collections import defaultdict
from typing import Sequence

import audit_jellyfin_series_identity as audit
import build_jellyfin_full_canonical_view as inv
import write_jellyfin_series_identity_nfos as identities

DEFAULT_SERVER = "http://127.0.0.1:8096"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"
DEFAULT_OUTPUT = "jellyfin-seven-series-detail.csv"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only inspection of Series / Season / Episode metadata for the seven unstable anime titles."
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    return parser.parse_args(argv)


def _provider_id(item: dict, provider: str) -> str:
    return audit._provider_id(item, provider)


def _has_primary_image(item: dict) -> bool:
    return audit._has_primary_image(item)


def _has_overview(item: dict) -> bool:
    return audit._has_overview(item)


def _target_for_series(path: str, view_root: str) -> dict | None:
    normalized = inv.normalize_windows_path(path)
    root = inv.normalize_windows_path(view_root)
    if not inv.path_under_or_equal(normalized, root):
        return None
    relative = ntpath.relpath(normalized, root)
    parts = relative.split("\\")
    if len(parts) < 2:
        return None
    group = parts[0]
    folder = parts[1]
    matches = [
        row
        for row in identities.SERIES_IDENTITIES
        if str(row["group"]).casefold() == group.casefold()
        and folder.casefold().startswith(str(row["directory_prefix"]).casefold())
    ]
    if len(matches) > 1:
        raise ValueError(f"multiple target identities match series path: {path}")
    return matches[0] if matches else None


def _fmt_index(value) -> str:
    if value is None or value == "":
        return "?"
    try:
        return str(int(value))
    except (TypeError, ValueError):
        return str(value)


def _series_flags(series: dict, seasons: Sequence[dict], episodes: Sequence[dict]) -> list[str]:
    flags: list[str] = []
    if not _provider_id(series, "Tvdb"):
        flags.append("SERIES_NO_TVDB")
    if not _has_overview(series):
        flags.append("SERIES_NO_OVERVIEW")
    if not _has_primary_image(series):
        flags.append("SERIES_NO_IMAGE")
    if any(item.get("IndexNumber") is None for item in seasons):
        flags.append("UNKNOWN_SEASON")
    if any(item.get("IndexNumber") is None for item in episodes):
        flags.append("EPISODE_NO_NUMBER")
    if any(item.get("ParentIndexNumber") is None for item in episodes):
        flags.append("EPISODE_NO_SEASON")
    if any(not _provider_id(item, "Tvdb") for item in episodes):
        flags.append("EPISODE_NO_TVDB")
    if any(not _has_overview(item) for item in episodes):
        flags.append("EPISODE_NO_OVERVIEW")
    if any(not _has_primary_image(item) for item in episodes):
        flags.append("EPISODE_NO_IMAGE")
    if any(
        audit.name_looks_path_derived(
            str(item.get("Name") or ""), str(item.get("Path") or ""), is_file=True
        )
        for item in episodes
    ):
        flags.append("EPISODE_NAME_LOCAL")
    return flags


def _item_row(target_title: str, item_type: str, item: dict) -> dict:
    return {
        "TargetTitle": target_title,
        "ItemType": item_type,
        "Name": str(item.get("Name") or ""),
        "ItemId": str(item.get("Id") or ""),
        "SeriesId": str(item.get("SeriesId") or (item.get("Id") if item_type == "Series" else "") or ""),
        "SeasonId": str(item.get("SeasonId") or (item.get("Id") if item_type == "Season" else "") or ""),
        "SeasonNumber": "" if item.get("ParentIndexNumber") is None else item.get("ParentIndexNumber"),
        "IndexNumber": "" if item.get("IndexNumber") is None else item.get("IndexNumber"),
        "TvdbId": _provider_id(item, "Tvdb"),
        "TmdbId": _provider_id(item, "Tmdb"),
        "ImdbId": _provider_id(item, "Imdb"),
        "HasOverview": _has_overview(item),
        "HasPrimaryImage": _has_primary_image(item),
        "NameLooksLocal": (
            audit.name_looks_path_derived(
                str(item.get("Name") or ""), str(item.get("Path") or ""), is_file=item_type == "Episode"
            )
            if str(item.get("Path") or "").strip()
            else False
        ),
        "Path": str(item.get("Path") or ""),
        "DateLastRefreshed": str(item.get("DateLastRefreshed") or ""),
        "DateLastSaved": str(item.get("DateLastSaved") or ""),
    }


def inspect(server: str, api_key: str, view_root: str) -> tuple[list[dict], list[dict]]:
    series_items = audit.get_paged_items(server, api_key, "Series")
    season_items = audit.get_paged_items(server, api_key, "Season")
    episode_items = audit.get_paged_items(server, api_key, "Episode")

    matched: list[tuple[dict, dict]] = []
    for series in series_items:
        path = str(series.get("Path") or "").strip()
        if not path:
            continue
        target = _target_for_series(path, view_root)
        if target:
            matched.append((target, series))

    by_title: dict[str, list[dict]] = defaultdict(list)
    for target, series in matched:
        by_title[str(target["title"])].append(series)

    expected_titles = [str(row["title"]) for row in identities.SERIES_IDENTITIES]
    bad = {title: len(by_title.get(title, [])) for title in expected_titles if len(by_title.get(title, [])) != 1}
    if bad:
        raise RuntimeError("expected exactly one Jellyfin Series per target: " + ", ".join(f"{k}={v}" for k, v in bad.items()))

    seasons_by_series: dict[str, list[dict]] = defaultdict(list)
    for item in season_items:
        seasons_by_series[str(item.get("SeriesId") or "")].append(item)

    episodes_by_series: dict[str, list[dict]] = defaultdict(list)
    for item in episode_items:
        episodes_by_series[str(item.get("SeriesId") or "")].append(item)

    detail_rows: list[dict] = []
    summaries: list[dict] = []
    for target in identities.SERIES_IDENTITIES:
        title = str(target["title"])
        series = by_title[title][0]
        series_id = str(series.get("Id") or "")
        seasons = sorted(
            seasons_by_series.get(series_id, []),
            key=lambda item: (item.get("IndexNumber") is None, item.get("IndexNumber") or 0, str(item.get("Name") or "")),
        )
        episodes = sorted(
            episodes_by_series.get(series_id, []),
            key=lambda item: (
                item.get("ParentIndexNumber") is None,
                item.get("ParentIndexNumber") or 0,
                item.get("IndexNumber") is None,
                item.get("IndexNumber") or 0,
                str(item.get("Name") or ""),
            ),
        )

        detail_rows.append(_item_row(title, "Series", series))
        detail_rows.extend(_item_row(title, "Season", item) for item in seasons)
        detail_rows.extend(_item_row(title, "Episode", item) for item in episodes)

        flags = _series_flags(series, seasons, episodes)
        summaries.append(
            {
                "title": title,
                "series": series,
                "seasons": seasons,
                "episodes": episodes,
                "flags": flags,
            }
        )

    return summaries, detail_rows


def write_csv(path: str, rows: Sequence[dict]) -> None:
    fields = [
        "TargetTitle",
        "ItemType",
        "Name",
        "ItemId",
        "SeriesId",
        "SeasonId",
        "SeasonNumber",
        "IndexNumber",
        "TvdbId",
        "TmdbId",
        "ImdbId",
        "HasOverview",
        "HasPrimaryImage",
        "NameLooksLocal",
        "Path",
        "DateLastRefreshed",
        "DateLastSaved",
    ]
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(summaries: Sequence[dict], output: str) -> None:
    print("\n=== Seven Series Metadata Layer Inspection ===")
    print("Mode: READ ONLY\n")
    for row in summaries:
        series = row["series"]
        seasons = row["seasons"]
        episodes = row["episodes"]
        flags = row["flags"]
        season_indexes = ",".join(_fmt_index(item.get("IndexNumber")) for item in seasons) or "-"
        print(
            f"[{row['title']}] current={series.get('Name') or '-'} :: "
            f"TVDB={_provider_id(series, 'Tvdb') or '-'} TMDB={_provider_id(series, 'Tmdb') or '-'} "
            f"IMDb={_provider_id(series, 'Imdb') or '-'} :: "
            f"series-overview={'Y' if _has_overview(series) else 'N'} series-image={'Y' if _has_primary_image(series) else 'N'}"
        )
        print(
            f"  seasons={len(seasons)} indexes={season_indexes}; episodes={len(episodes)}; "
            f"numbered={sum(item.get('IndexNumber') is not None for item in episodes)}; "
            f"seasoned={sum(item.get('ParentIndexNumber') is not None for item in episodes)}; "
            f"episode-tvdb={sum(bool(_provider_id(item, 'Tvdb')) for item in episodes)}; "
            f"overview={sum(_has_overview(item) for item in episodes)}; "
            f"image={sum(_has_primary_image(item) for item in episodes)}; "
            f"local-name={sum(audit.name_looks_path_derived(str(item.get('Name') or ''), str(item.get('Path') or ''), is_file=True) for item in episodes)}"
        )
        print(f"  flags={'|'.join(flags) if flags else 'OK'}")

        problem_episodes = [
            item
            for item in episodes
            if item.get("IndexNumber") is None
            or item.get("ParentIndexNumber") is None
            or not _provider_id(item, "Tvdb")
            or not _has_overview(item)
            or not _has_primary_image(item)
            or audit.name_looks_path_derived(str(item.get("Name") or ""), str(item.get("Path") or ""), is_file=True)
        ]
        for item in problem_episodes[:4]:
            print(
                f"    S{_fmt_index(item.get('ParentIndexNumber'))}E{_fmt_index(item.get('IndexNumber'))} "
                f"{item.get('Name') or '-'} :: TVDB={_provider_id(item, 'Tvdb') or '-'} "
                f"overview={'Y' if _has_overview(item) else 'N'} image={'Y' if _has_primary_image(item) else 'N'}"
            )
        if len(problem_episodes) > 4:
            print(f"    ... {len(problem_episodes) - 4} more problem episode(s) in CSV")
        print("")

    print(f"CSV: {output}")
    print("READ ONLY: no refresh, Identify, metadata write, NFO write, library setting change, or database change was performed.")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    summaries, detail_rows = inspect(args.server, args.api_key, args.view_root)
    write_csv(args.output, detail_rows)
    print_summary(summaries, args.output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
