#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from typing import Callable, Sequence

import build_jellyfin_full_canonical_view as inv

DEFAULT_SERVER = "http://127.0.0.1:8096"
DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clone one configured Jellyfin TV library into the direct child groups under View-v3."
    )
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--template-library", required=True, help="Exact Jellyfin TV library name to copy settings from")
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--apply", action="store_true", help="Actually create missing libraries; default is dry-run")
    return parser.parse_args(argv)


def _authorization(api_key: str) -> str:
    return (
        'MediaBrowser Client="grouped-library-python", Device="Python", '
        f'DeviceId="grouped-library-python", Version="1.0", Token="{api_key}"'
    )


def jellyfin_request(
    server: str,
    api_key: str,
    method: str,
    path: str,
    query: dict | None = None,
    body: dict | None = None,
):
    url = server.rstrip("/") + "/" + path.lstrip("/")
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)

    data = None
    headers = {"Authorization": _authorization(api_key)}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
        if not raw:
            return None
        content_type = response.headers.get("Content-Type", "")
        if "json" in content_type.lower():
            return json.loads(raw.decode("utf-8"))
        return raw.decode("utf-8", errors="replace")


def flatten_virtual_folders(value) -> list[dict]:
    result: list[dict] = []
    queue = [value]
    while queue:
        current = queue.pop(0)
        if current is None:
            continue
        if isinstance(current, dict) and {"Name", "CollectionType", "Locations"}.issubset(current):
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


def clone_library_options(template_options: dict, target_path: str) -> dict:
    cloned = copy.deepcopy(template_options or {})
    cloned["PathInfos"] = [{"Path": inv.normalize_windows_path(target_path)}]
    return cloned


def format_group_library_name(directory_name: str) -> str:
    name = str(directory_name or "").strip()
    match = re.fullmatch(r"(\d{4})年([1-9])月新番", name)
    if not match:
        return name
    return f"{match.group(1)}年{int(match.group(2)):02d}月新番"


def discover_targets(view_root: str) -> list[dict]:
    logical_root = inv.normalize_windows_path(view_root)
    physical_root = inv._to_extended_windows_path(logical_root) if os.name == "nt" else logical_root
    if not os.path.isdir(physical_root):
        raise FileNotFoundError(f"View-v3 root not found: {logical_root}")

    targets: list[dict] = []
    with os.scandir(physical_root) as entries:
        for entry in entries:
            if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                continue
            directory_name = entry.name.strip()
            if not directory_name:
                continue
            targets.append(
                {
                    "name": format_group_library_name(directory_name),
                    "path": inv.normalize_windows_path(os.path.join(logical_root, directory_name)),
                }
            )

    targets.sort(key=lambda row: row["name"].casefold())
    if not targets:
        raise RuntimeError(f"no direct child directories found under {logical_root}")
    return targets


def _location_keys(folder: dict) -> set[str]:
    return {
        inv.path_key(str(location))
        for location in (folder.get("Locations") or [])
        if str(location).strip()
    }


def build_plan(targets: Sequence[dict], virtual_folders, template_name: str = "") -> list[dict]:
    existing = flatten_virtual_folders(virtual_folders)
    template_key = str(template_name or "").strip().casefold()
    plan: list[dict] = []

    for target in targets:
        name = str(target["name"]).strip()
        path = inv.normalize_windows_path(target["path"])
        target_key = inv.path_key(path)

        same_name = [folder for folder in existing if str(folder.get("Name", "")).strip().casefold() == name.casefold()]
        if same_name:
            folder = same_name[0]
            locations = _location_keys(folder)
            if str(folder.get("CollectionType") or "") == "tvshows" and locations == {target_key}:
                plan.append({"name": name, "path": path, "state": "SKIP"})
                continue
            raise ValueError(
                f"same library name already exists with different type/path: {name} :: "
                f"type={folder.get('CollectionType')} locations={folder.get('Locations')}"
            )

        path_owners = [folder for folder in existing if target_key in _location_keys(folder)]
        blocking_owners = [
            folder
            for folder in path_owners
            if not template_key
            or str(folder.get("Name", "")).strip().casefold() != template_key
        ]
        if blocking_owners:
            owner = blocking_owners[0]
            raise ValueError(
                f"same library path already belongs to another library: {path} :: {owner.get('Name')}"
            )

        plan.append({"name": name, "path": path, "state": "CREATE"})

    return plan


def find_template(virtual_folders, template_name: str) -> dict:
    matches = [
        folder
        for folder in flatten_virtual_folders(virtual_folders)
        if str(folder.get("Name", "")).strip() == template_name
    ]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one template library named {template_name!r}, found {len(matches)}")
    template = matches[0]
    if str(template.get("CollectionType") or "") != "tvshows":
        raise ValueError(f"template library is not tvshows: {template_name}")
    if not isinstance(template.get("LibraryOptions"), dict):
        raise ValueError(f"template library has no LibraryOptions: {template_name}")
    return template


def apply_plan(
    server: str,
    api_key: str,
    template_options: dict,
    plan: Sequence[dict],
    request_fn: Callable = jellyfin_request,
) -> int:
    created = 0
    for row in plan:
        if row["state"] != "CREATE":
            continue
        options = clone_library_options(template_options, row["path"])
        request_fn(
            server,
            api_key,
            "POST",
            "/Library/VirtualFolders",
            query={
                "name": row["name"],
                "collectionType": "tvshows",
                "paths": [row["path"]],
                "refreshLibrary": "false",
            },
            body={"LibraryOptions": options},
        )
        created += 1

    if created:
        request_fn(server, api_key, "POST", "/Library/Refresh")
    return created


def print_plan(template: dict, view_root: str, plan: Sequence[dict]) -> None:
    creates = sum(row["state"] == "CREATE" for row in plan)
    skips = sum(row["state"] == "SKIP" for row in plan)
    print("\n=== Jellyfin Grouped Library Plan ===")
    print(f"Template:   {template['Name']}")
    print(f"View root:  {inv.normalize_windows_path(view_root)}")
    print(f"Targets:    {len(plan)}")
    print(f"To create:  {creates}")
    print(f"Already OK: {skips}")
    print("")
    for row in plan:
        print(f"[{row['state']:<6}] {row['name']} -> {row['path']}")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    virtual_folders = jellyfin_request(args.server, args.api_key, "GET", "/Library/VirtualFolders")
    template = find_template(virtual_folders, args.template_library)
    targets = discover_targets(args.view_root)
    plan = build_plan(targets, virtual_folders, template_name=template["Name"])
    print_plan(template, args.view_root, plan)

    if not args.apply:
        print("\nDRY RUN finished. Jellyfin was not changed.")
        return 0

    # Re-read immediately before mutation so stale library state cannot silently overwrite the plan.
    virtual_folders = jellyfin_request(args.server, args.api_key, "GET", "/Library/VirtualFolders")
    template = find_template(virtual_folders, args.template_library)
    plan = build_plan(targets, virtual_folders, template_name=template["Name"])
    created = apply_plan(args.server, args.api_key, template["LibraryOptions"], plan)
    print(f"\nCreated {created} grouped libraries.")
    if created:
        print("Triggered one Jellyfin library refresh after all creates.")
    else:
        print("Nothing to create; no refresh was triggered.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
