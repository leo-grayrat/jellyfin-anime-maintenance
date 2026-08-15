#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import ntpath
import os
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from typing import Callable, Sequence

ACTIVE_STATUS = "CONFIRMED"
TV_BUCKETS = {"TV_MAIN", "TV_EXTRA", "TV_SPECIAL", "U149_MULTI", "ANOTHER_WORLD"}
MOVIE_BUCKETS = {"MOVIE", "MOVIE_EXTRA"}
REQUIRED_FIELDS = {
    "LibraryGroup",
    "CatalogBucket",
    "TargetRelativePath",
    "Status",
    "SourceVolume",
}


def path_key(path: str) -> str:
    return ntpath.normpath(str(path).strip().replace("/", "\\")).rstrip("\\").casefold()


def join_windows(root: str, child: str) -> str:
    return ntpath.normpath(ntpath.join(root, child))


def first_component(path: str) -> str:
    normalized = ntpath.normpath(str(path).strip().replace("/", "\\"))
    return normalized.split("\\", 1)[0]


def collection_type_for_buckets(group: str, buckets: set[str]) -> str:
    unknown = sorted(buckets - TV_BUCKETS - MOVIE_BUCKETS)
    if unknown:
        raise ValueError(f"{group}: unsupported CatalogBucket(s): {', '.join(unknown)}")
    has_tv = bool(buckets & TV_BUCKETS)
    has_movie = bool(buckets & MOVIE_BUCKETS)
    if has_tv and has_movie:
        raise ValueError(f"{group}: LibraryGroup mixes TV and movie rows")
    if has_movie:
        return "movies"
    if has_tv:
        return "tvshows"
    raise ValueError(f"{group}: no active media rows")


def plan_libraries(
    manifest_path: str,
    c_root: str,
    d_root: str,
    name_prefix: str = "新视图-",
) -> list[dict]:
    with open(manifest_path, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = sorted(REQUIRED_FIELDS - set(reader.fieldnames or []))
        if missing:
            raise ValueError(f"manifest missing required column(s): {', '.join(missing)}")
        rows = list(reader)

    groups: dict[str, dict] = defaultdict(lambda: {"buckets": set(), "volumes": set(), "rows": 0})
    for index, row in enumerate(rows, start=2):
        status = (row.get("Status") or "").strip().upper()
        if status != ACTIVE_STATUS:
            continue
        group = (row.get("LibraryGroup") or "").strip()
        bucket = (row.get("CatalogBucket") or "").strip().upper()
        relative = (row.get("TargetRelativePath") or "").strip()
        volume = (row.get("SourceVolume") or "").strip().upper()
        if not group:
            raise ValueError(f"row {index}: active row is missing LibraryGroup")
        if not relative:
            raise ValueError(f"row {index}: active row is missing TargetRelativePath")
        if first_component(relative).casefold() != group.casefold():
            raise ValueError(
                f"row {index}: TargetRelativePath does not start with LibraryGroup: "
                f"{relative!r} vs {group!r}"
            )
        if volume not in {"C:", "D:"}:
            raise ValueError(f"row {index}: unsupported SourceVolume={volume!r}")
        groups[group]["buckets"].add(bucket)
        groups[group]["volumes"].add(volume)
        groups[group]["rows"] += 1

    roots = {"C:": c_root, "D:": d_root}
    plans: list[dict] = []
    for group in sorted(groups, key=str.casefold):
        info = groups[group]
        locations = [join_windows(roots[v], group) for v in ("C:", "D:") if v in info["volumes"]]
        plans.append(
            {
                "group": group,
                "name": f"{name_prefix}{group}",
                "collection_type": collection_type_for_buckets(group, info["buckets"]),
                "locations": locations,
                "row_count": info["rows"],
                "state": "UNCLASSIFIED",
                "reason": "",
            }
        )
    return plans


def flatten_virtual_folders(value) -> list[dict]:
    result: list[dict] = []
    queue = [value]
    while queue:
        current = queue.pop(0)
        if current is None:
            continue
        if isinstance(current, dict):
            if "Name" in current and ("Locations" in current or "CollectionType" in current):
                result.append(current)
            elif isinstance(current.get("Items"), list):
                queue.extend(current["Items"])
            else:
                for child in current.values():
                    if isinstance(child, (dict, list, tuple)):
                        queue.append(child)
            continue
        if isinstance(current, (list, tuple)):
            queue.extend(current)
            continue
        raise ValueError("unexpected Jellyfin virtual-folder response shape")
    return result


def classify_existing(plans: Sequence[dict], virtual_folders) -> list[dict]:
    by_name: dict[str, list[dict]] = defaultdict(list)
    for existing in flatten_virtual_folders(virtual_folders):
        name = str(existing.get("Name") or "").strip()
        if name:
            by_name[name.casefold()].append(existing)

    classified = []
    for source in plans:
        row = dict(source)
        matches = by_name.get(row["name"].casefold(), [])
        if not matches:
            row["state"] = "MISSING"
            row["reason"] = "library does not exist"
        elif len(matches) != 1:
            row["state"] = "CONFLICT"
            row["reason"] = f"{len(matches)} existing libraries share this name"
        else:
            existing = matches[0]
            actual_type = str(existing.get("CollectionType") or "").strip().casefold()
            expected_type = row["collection_type"].casefold()
            actual_locations = {path_key(x) for x in (existing.get("Locations") or [])}
            expected_locations = {path_key(x) for x in row["locations"]}
            if actual_type != expected_type:
                row["state"] = "CONFLICT"
                row["reason"] = (
                    f"collection type differs: existing={actual_type or '<blank>'} "
                    f"expected={expected_type}"
                )
            elif actual_locations != expected_locations:
                row["state"] = "CONFLICT"
                row["reason"] = (
                    "locations differ: existing="
                    + " | ".join(sorted(existing.get("Locations") or [], key=str.casefold))
                )
            else:
                row["state"] = "REUSABLE"
                row["reason"] = "same name, type and locations"
        classified.append(row)
    return classified


def ensure_no_conflicts(plans: Sequence[dict]) -> None:
    conflicts = [row for row in plans if row.get("state") == "CONFLICT"]
    if conflicts:
        details = " | ".join(f"{x['name']}: {x['reason']}" for x in conflicts[:10])
        raise ValueError(f"library preflight found {len(conflicts)} conflict(s): {details}")


def validate_location_directories(plans: Sequence[dict]) -> None:
    missing = []
    for row in plans:
        for location in row["locations"]:
            if not os.path.isdir(location):
                missing.append(location)
    if missing:
        raise FileNotFoundError(
            f"{len(missing)} planned library location(s) do not exist: " + " | ".join(missing[:10])
        )


def auth_header(api_key: str) -> str:
    return (
        'MediaBrowser Client="anime-manifest-library-builder", Device="Python", '
        f'DeviceId="anime-manifest-library-builder", Version="1.0", Token="{api_key}"'
    )


def jellyfin_get(server: str, api_key: str, path: str):
    url = server.rstrip("/") + "/" + path.lstrip("/")
    request = urllib.request.Request(
        url,
        headers={"Authorization": auth_header(api_key)},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Jellyfin GET {path} failed: HTTP {exc.code}: {body}") from exc


def jellyfin_post(server: str, api_key: str, path: str, query: dict | None = None):
    url = server.rstrip("/") + "/" + path.lstrip("/")
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    request = urllib.request.Request(
        url,
        data=b"",
        headers={"Authorization": auth_header(api_key)},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60):
            return None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Jellyfin POST {path} failed: HTTP {exc.code}: {body}") from exc


def apply_libraries(
    plans: Sequence[dict],
    server: str,
    api_key: str,
    post: Callable = jellyfin_post,
) -> dict:
    ensure_no_conflicts(plans)
    created = 0
    reused = 0
    for row in plans:
        state = row.get("state")
        if state == "REUSABLE":
            reused += 1
            continue
        if state != "MISSING":
            raise ValueError(f"cannot apply library in state {state!r}: {row['name']}")
        post(
            server,
            api_key,
            "/Library/VirtualFolders",
            {
                "name": row["name"],
                "collectionType": row["collection_type"],
                "paths": row["locations"],
                "refreshLibrary": "false",
            },
        )
        created += 1
    if created:
        post(server, api_key, "/Library/Refresh", None)
    return {"created": created, "reused": reused}


def print_plan(plans: Sequence[dict]) -> None:
    for row in plans:
        print(f"[{row['state']}] {row['name']} ({row['collection_type']}, {row['row_count']} media rows)")
        for location in row["locations"]:
            print(f"  - {location}")
        if row.get("reason"):
            print(f"    {row['reason']}")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Create new Jellyfin libraries from the reviewed anime decision manifest."
    )
    parser.add_argument("manifest", help="Reviewed private manifest CSV")
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--api-key", default=os.environ.get("JELLYFIN_API_KEY"))
    parser.add_argument("--c-root", default=r"C:\resource\video\anime")
    parser.add_argument("--d-root", default=r"D:\Resource\BangumiLink\View")
    parser.add_argument("--name-prefix", default="新视图-")
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    if not args.api_key:
        raise SystemExit("Jellyfin API key is required: pass --api-key or set JELLYFIN_API_KEY")

    plans = plan_libraries(args.manifest, args.c_root, args.d_root, args.name_prefix)
    validate_location_directories(plans)
    existing = jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    classified = classify_existing(plans, existing)
    print_plan(classified)

    counts = Counter(row["state"] for row in classified)
    print()
    print(f"Planned libraries: {len(classified)}")
    print(f"Missing:           {counts.get('MISSING', 0)}")
    print(f"Reusable:          {counts.get('REUSABLE', 0)}")
    print(f"Conflicts:         {counts.get('CONFLICT', 0)}")
    ensure_no_conflicts(classified)

    if not args.apply:
        print("Mode: DRY-RUN (no Jellyfin changes)")
        return 0

    result = apply_libraries(classified, args.server, args.api_key)
    print("Mode: APPLY")
    print(f"Created:           {result['created']}")
    print(f"Reused:            {result['reused']}")
    print("One full library refresh was queued after creation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
