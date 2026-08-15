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

TMDB = "TheMovieDb"
TVDB = "TheTVDB"
OMDB = "The Open Movie Database"
EMBEDDED_IMAGE = "Embedded Image Extractor"
SCREEN_GRABBER = "Screen Grabber"

METADATA_PRIORITY = (TMDB,)
IMAGE_PRIORITY = (
    TVDB,
    OMDB,
    TMDB,
    EMBEDDED_IMAGE,
    SCREEN_GRABBER,
    "Dynamic Image Provider",
    "Image Extractor",
)
TV_EXPLICIT_IMAGE_PROVIDERS = {TVDB, TMDB}
MOVIE_EXPLICIT_IMAGE_PROVIDERS = {TVDB, OMDB, TMDB, EMBEDDED_IMAGE, SCREEN_GRABBER}
PROVIDER_OPTION_FIELDS = (
    "MetadataFetchers",
    "MetadataFetcherOrder",
    "ImageFetchers",
    "ImageFetcherOrder",
)


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
                "name": group,
                "collection_type": collection_type_for_buckets(group, info["buckets"]),
                "locations": locations,
                "row_count": info["rows"],
                "state": "UNCLASSIFIED",
                "reason": "",
            }
        )
    return plans


def _plugin_names(plugins) -> list[str]:
    result = []
    for plugin in plugins or []:
        name = str(plugin.get("Name") or "").strip()
        if name:
            result.append(name)
    return result


def _ordered_plugin_names(plugins, priority: Sequence[str]) -> list[str]:
    names = _plugin_names(plugins)
    rank = {name.casefold(): index for index, name in enumerate(priority)}
    indexed = list(enumerate(names))
    indexed.sort(key=lambda pair: (rank.get(pair[1].casefold(), len(rank)), pair[0]))
    return [name for _, name in indexed]


def _enabled_plugin_names(plugins, order: Sequence[str], explicit: set[str]) -> list[str]:
    by_name = {
        str(plugin.get("Name") or "").strip(): plugin
        for plugin in (plugins or [])
        if str(plugin.get("Name") or "").strip()
    }
    enabled = []
    for name in order:
        plugin = by_name[name]
        if bool(plugin.get("DefaultEnabled")) or name in explicit:
            enabled.append(name)
    return enabled


def _find_type_option(available_options: dict, type_name: str) -> dict | None:
    for row in available_options.get("TypeOptions") or []:
        if str(row.get("Type") or "").casefold() == type_name.casefold():
            return row
    return None


def _provider_signature(library_options: dict) -> dict[str, dict[str, list[str]]]:
    result: dict[str, dict[str, list[str]]] = {}
    for row in library_options.get("TypeOptions") or []:
        type_name = str(row.get("Type") or "").strip()
        if not type_name:
            continue
        fields: dict[str, list[str]] = {}
        for field in PROVIDER_OPTION_FIELDS:
            fields[field] = [str(x) for x in (row.get(field) or [])]
        result[type_name.casefold()] = fields
    return result


def validate_requested_provider_capabilities(available_options: dict, collection_type: str) -> None:
    if collection_type == "tvshows":
        target_type = "Series"
        required_images = {TVDB, TMDB}
    elif collection_type == "movies":
        target_type = "Movie"
        required_images = {TVDB, OMDB, TMDB, EMBEDDED_IMAGE, SCREEN_GRABBER}
    else:
        raise ValueError(f"unsupported collection type for provider policy: {collection_type}")

    type_option = _find_type_option(available_options, target_type)
    if not type_option:
        raise ValueError(f"Jellyfin did not return provider options for {target_type}")

    metadata_names = set(_plugin_names(type_option.get("MetadataFetchers")))
    if TMDB not in metadata_names:
        raise ValueError(f"{target_type}: {TMDB} metadata provider is not available")

    image_names = set(_plugin_names(type_option.get("ImageFetchers")))
    missing_images = sorted(required_images - image_names)
    if missing_images:
        raise ValueError(
            f"{target_type}: expected image provider(s) are not available: {', '.join(missing_images)}"
        )


def build_library_options(available_options: dict, collection_type: str) -> dict:
    validate_requested_provider_capabilities(available_options, collection_type)
    explicit_images = (
        TV_EXPLICIT_IMAGE_PROVIDERS if collection_type == "tvshows" else MOVIE_EXPLICIT_IMAGE_PROVIDERS
    )

    type_options = []
    for available in available_options.get("TypeOptions") or []:
        type_name = str(available.get("Type") or "").strip()
        if not type_name:
            continue

        metadata_plugins = available.get("MetadataFetchers") or []
        image_plugins = available.get("ImageFetchers") or []
        metadata_order = _ordered_plugin_names(metadata_plugins, METADATA_PRIORITY)
        image_order = _ordered_plugin_names(image_plugins, IMAGE_PRIORITY)

        row = {"Type": type_name}
        if metadata_order:
            row["MetadataFetcherOrder"] = metadata_order
            row["MetadataFetchers"] = _enabled_plugin_names(metadata_plugins, metadata_order, {TMDB})
        if image_order:
            row["ImageFetcherOrder"] = image_order
            row["ImageFetchers"] = _enabled_plugin_names(image_plugins, image_order, explicit_images)
        type_options.append(row)

    return {
        "EnableInternetProviders": True,
        "TypeOptions": type_options,
    }


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


def verify_saved_libraries(plans: Sequence[dict], virtual_folders) -> None:
    by_name: dict[str, list[dict]] = defaultdict(list)
    for existing in flatten_virtual_folders(virtual_folders):
        name = str(existing.get("Name") or "").strip()
        if name:
            by_name[name.casefold()].append(existing)

    errors = []
    for row in plans:
        matches = by_name.get(row["name"].casefold(), [])
        if len(matches) != 1:
            errors.append(f"{row['name']}: expected exactly one saved library, found {len(matches)}")
            continue

        existing = matches[0]
        actual_type = str(existing.get("CollectionType") or "").strip().casefold()
        if actual_type != row["collection_type"].casefold():
            errors.append(
                f"{row['name']}: saved collection type differs: {actual_type or '<blank>'}"
            )
            continue

        actual_locations = {path_key(x) for x in (existing.get("Locations") or [])}
        expected_locations = {path_key(x) for x in row["locations"]}
        if actual_locations != expected_locations:
            errors.append(f"{row['name']}: saved locations differ")
            continue

        actual_options = existing.get("LibraryOptions") or {}
        expected_options = row.get("library_options") or {}
        if bool(actual_options.get("EnableInternetProviders")) != bool(
            expected_options.get("EnableInternetProviders")
        ):
            errors.append(f"{row['name']}: EnableInternetProviders was not saved as requested")
            continue

        actual_signature = _provider_signature(actual_options)
        expected_signature = _provider_signature(expected_options)
        for type_name, expected_fields in expected_signature.items():
            actual_fields = actual_signature.get(type_name)
            if actual_fields is None:
                errors.append(f"{row['name']}: saved LibraryOptions missing type {type_name}")
                break
            for field, expected_value in expected_fields.items():
                if actual_fields.get(field, []) != expected_value:
                    errors.append(
                        f"{row['name']}: saved {type_name}.{field} differs: "
                        f"actual={actual_fields.get(field, [])!r} expected={expected_value!r}"
                    )
                    break
            else:
                continue
            break

    if errors:
        raise ValueError(
            f"saved library verification failed with {len(errors)} error(s): "
            + " | ".join(errors[:10])
        )


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


def jellyfin_get(server: str, api_key: str, path: str, query: dict | None = None):
    url = server.rstrip("/") + "/" + path.lstrip("/")
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
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


def jellyfin_post(
    server: str,
    api_key: str,
    path: str,
    query: dict | None = None,
    body: dict | None = None,
):
    url = server.rstrip("/") + "/" + path.lstrip("/")
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else b""
    headers = {"Authorization": auth_header(api_key)}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=60):
            return None
    except urllib.error.HTTPError as exc:
        response_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Jellyfin POST {path} failed: HTTP {exc.code}: {response_body}") from exc


def attach_library_options(plans: Sequence[dict], server: str, api_key: str) -> None:
    by_collection_type: dict[str, dict] = {}
    for collection_type in sorted({row["collection_type"] for row in plans}):
        available = jellyfin_get(
            server,
            api_key,
            "/Libraries/AvailableOptions",
            {
                "LibraryContentType": collection_type,
                "IsNewLibrary": "true",
            },
        )
        by_collection_type[collection_type] = build_library_options(available, collection_type)

    for row in plans:
        row["library_options"] = by_collection_type[row["collection_type"]]


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
            {"LibraryOptions": row["library_options"]},
        )
        created += 1
    return {"created": created, "reused": reused}


def print_plan(plans: Sequence[dict]) -> None:
    for row in plans:
        print(f"[{row['state']}] {row['name']} ({row['collection_type']}, {row['row_count']} media rows)")
        for location in row["locations"]:
            print(f"  - {location}")
        if row.get("reason"):
            print(f"    {row['reason']}")


def print_provider_policy(plans: Sequence[dict]) -> None:
    seen = set()
    print("\nProvider policy:")
    for row in plans:
        collection_type = row["collection_type"]
        if collection_type in seen:
            continue
        seen.add(collection_type)
        print(f"- {collection_type}")
        for type_option in row["library_options"].get("TypeOptions") or []:
            metadata = type_option.get("MetadataFetchers") or []
            images = type_option.get("ImageFetchers") or []
            if not metadata and not images:
                continue
            print(f"  {type_option['Type']}:")
            if metadata:
                print("    metadata: " + " -> ".join(metadata))
            if images:
                print("    images:   " + " -> ".join(images))


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Create replacement Jellyfin libraries from the reviewed anime decision manifest."
    )
    parser.add_argument("manifest", help="Reviewed private manifest CSV")
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--api-key", default=os.environ.get("JELLYFIN_API_KEY"))
    parser.add_argument("--c-root", default=r"C:\resource\video\anime")
    parser.add_argument("--d-root", default=r"D:\Resource\BangumiLink\View")
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    if not args.api_key:
        raise SystemExit("Jellyfin API key is required: pass --api-key or set JELLYFIN_API_KEY")

    plans = plan_libraries(args.manifest, args.c_root, args.d_root)
    validate_location_directories(plans)
    attach_library_options(plans, args.server, args.api_key)
    existing = jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    classified = classify_existing(plans, existing)
    print_plan(classified)
    print_provider_policy(classified)

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
    saved = jellyfin_get(args.server, args.api_key, "/Library/VirtualFolders")
    verify_saved_libraries(classified, saved)
    print(f"Verified saved libraries: {len(classified)}")

    if result["created"]:
        jellyfin_post(args.server, args.api_key, "/Library/Refresh", None, None)

    print("Mode: APPLY")
    print(f"Created:           {result['created']}")
    print(f"Reused:            {result['reused']}")
    if result["created"]:
        print("Saved library settings verified; one full library refresh was queued.")
    else:
        print("Saved library settings verified; no new library was created, so no refresh was queued.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
